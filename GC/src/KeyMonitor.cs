using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Windows.Forms;
using System.IO;

namespace GrammarChecker
{
    class Program
    {
        private const int WH_KEYBOARD_LL = 13;
        private const int WH_MOUSE_LL = 14;
        private const int WM_KEYDOWN = 0x0100;
        private const int WM_SYSKEYDOWN = 0x0104;
        private const int WM_RBUTTONUP = 0x0205;
        private const int WM_MBUTTONUP = 0x0208;
        private const uint CF_UNICODETEXT = 13;

        private static LowLevelKeyboardProc _proc = HookCallback;
        private static LowLevelMouseProc _mouseProc = HookCallbackMouse;
        private static IntPtr _hookID = IntPtr.Zero;
        private static IntPtr _mouseHookID = IntPtr.Zero;
        private static IntPtr _winEventHook = IntPtr.Zero;

        private const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
        private const uint WINEVENT_OUTOFCONTEXT = 0x0000;

        private delegate void WinEventDelegate(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);
        private static WinEventDelegate _winEventDelegate = WinEventProc;

        private static readonly object _lock = new object();
        private static Dictionary<string, StringBuilder> _buffers = new Dictionary<string, StringBuilder>();
        private static Dictionary<string, int> _cursorPositions = new Dictionary<string, int>();
        private static Dictionary<string, IntPtr> _targetHwnds = new Dictionary<string, IntPtr>();
        private static string _activeTargetId = "terminal";
        private static string _activeTargetName = "Terminal";
        private static bool _isRecording = false;
        private static volatile bool _isSelfPasting = false;

        private static IntPtr _cachedHwnd = IntPtr.Zero;
        private static bool _cachedIsTarget = false;
        private static string _cachedTargetId = "terminal";
        private static string _cachedTargetName = "Terminal";
        private static bool _cachedIsEditor = false;
        private static bool _isForegroundNotepad = false;
        private static int _cachedTick = 0;
        private static bool _wasLastForegroundTarget = false;

        private static StringBuilder GetBufferForTarget(string targetId)
        {
            if (string.IsNullOrEmpty(targetId)) targetId = "terminal";
            if (!_buffers.ContainsKey(targetId))
            {
                _buffers[targetId] = new StringBuilder();
            }
            return _buffers[targetId];
        }

        private static int GetCursorPosForTarget(string targetId)
        {
            if (string.IsNullOrEmpty(targetId)) targetId = "terminal";
            if (!_cursorPositions.ContainsKey(targetId))
            {
                _cursorPositions[targetId] = 0;
            }
            return _cursorPositions[targetId];
        }

        private static void SetCursorPosForTarget(string targetId, int pos)
        {
            if (string.IsNullOrEmpty(targetId)) targetId = "terminal";
            _cursorPositions[targetId] = pos;
        }

        private static StringBuilder _buffer
        {
            get { return GetBufferForTarget(_activeTargetId); }
        }

        private static int _cursorPos
        {
            get { return GetCursorPosForTarget(_activeTargetId); }
            set { SetCursorPosForTarget(_activeTargetId, value); }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT
        {
            public int x;
            public int y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSLLHOOKSTRUCT
        {
            public POINT pt;
            public uint mouseData;
            public uint flags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc lpfn, IntPtr hMod, uint dwThreadId);

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr GetModuleHandle(string lpModuleName);

        [DllImport("user32.dll")]
        private static extern int ToUnicode(uint wVirtKey, uint wScanCode, byte[] lpKeyState, [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pwszBuff, int cchBuff, uint wFlags);

        [DllImport("user32.dll")]
        private static extern bool GetKeyboardState(byte[] lpKeyState);

        [DllImport("user32.dll")]
        private static extern short GetKeyState(int nVirtKey);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool OpenClipboard(IntPtr hWndNewOwner);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool CloseClipboard();

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr GetClipboardData(uint uFormat);

        [DllImport("user32.dll")]
        private static extern uint GetClipboardSequenceNumber();

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        [DllImport("user32.dll")]
        private static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

        [DllImport("user32.dll")]
        private static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GlobalLock(IntPtr hMem);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GlobalUnlock(IntPtr hMem);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc, WinEventDelegate lpfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnhookWinEvent(IntPtr hWinEventHook);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool BringWindowToTop(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern void SwitchToThisWindow(IntPtr hWnd, bool fAltTab);

        [DllImport("user32.dll")]
        private static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int vKey);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        private static extern bool IsWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);

        private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);
        private delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

        [STAThread]
        static void Main(string[] args)
        {
            try
            {
                Console.OutputEncoding = Encoding.UTF8;
                Console.InputEncoding = Encoding.UTF8;
            }
            catch { }

            _hookID = SetHook(_proc);
            _mouseHookID = SetMouseHook(_mouseProc);
            _winEventHook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, _winEventDelegate, 0, 0, WINEVENT_OUTOFCONTEXT);
            CheckForegroundWindow(GetForegroundWindow());

            // Read commands from stdin in background thread
            System.Threading.ThreadPool.QueueUserWorkItem((state) =>
            {
                string line;
                while ((line = Console.ReadLine()) != null)
                {
                    line = line.Trim();
                    if (line == "START")
                    {
                        lock (_lock)
                        {
                            _isRecording = true;
                            GetBufferForTarget(_activeTargetId).Clear();
                            SetCursorPosForTarget(_activeTargetId, 0);
                            if (!_targetHwnds.ContainsKey(_activeTargetId) || !IsWindow(_targetHwnds[_activeTargetId]) || !IsWindowVisible(_targetHwnds[_activeTargetId]))
                            {
                                IntPtr fallback = FindTargetWindow(_activeTargetId);
                                if (fallback != IntPtr.Zero)
                                {
                                    _targetHwnds[_activeTargetId] = fallback;
                                }
                            }
                        }
                        Console.WriteLine("{\"event\":\"started\"}");
                        CheckForegroundWindow(GetForegroundWindow());
                    }
                    else if (line.StartsWith("CLEAR"))
                    {
                        string target = null;
                        if (line.Length > 5)
                        {
                            target = line.Substring(5).Trim();
                        }
                        if (string.IsNullOrEmpty(target))
                        {
                            target = _activeTargetId;
                        }
                        lock (_lock)
                        {
                            GetBufferForTarget(target).Clear();
                            SetCursorPosForTarget(target, 0);
                        }
                        Console.WriteLine("{\"event\":\"cleared\",\"target\":\"" + target + "\"}");
                    }
                    else if (line == "STOP")
                    {
                        string captured;
                        lock (_lock)
                        {
                            _isRecording = false;
                            captured = GetBufferForTarget(_activeTargetId).ToString();
                            GetBufferForTarget(_activeTargetId).Clear();
                            SetCursorPosForTarget(_activeTargetId, 0);
                        }
                        string escaped = EscapeJson(captured);
                        Console.WriteLine("{\"event\":\"stopped\",\"target\":\"" + _activeTargetId + "\",\"text\":\"" + escaped + "\"}");
                    }
                    else if (line == "STATUS")
                    {
                        lock (_lock)
                        {
                            StringBuilder buf = GetBufferForTarget(_activeTargetId);
                            string text = buf.ToString();
                            int wordCount = CountWords(text);
                            Console.WriteLine("{\"event\":\"status\",\"target\":\"" + _activeTargetId + "\",\"recording\":" + (_isRecording ? "true" : "false") + ",\"length\":" + text.Length + ",\"words\":" + wordCount + ",\"text\":\"" + EscapeJson(text) + "\"}");
                        }
                    }
                    else if (line.StartsWith("PASTE"))
                    {
                        string target = null;
                        if (line.Length > 5)
                        {
                            target = line.Substring(5).Trim();
                        }
                        if (string.IsNullOrEmpty(target))
                        {
                            target = _activeTargetId;
                        }
                        System.Threading.ThreadPool.QueueUserWorkItem((s) =>
                        {
                            ActivateAndPasteToTarget(target);
                        });
                    }
                    else if (line == "EXIT")
                    {
                        Application.Exit();
                        break;
                    }
                }
            });

            // Watchdog thread: Monitor if linked target windows close or hide, and notify GC immediately
            System.Threading.ThreadPool.QueueUserWorkItem((state) =>
            {
                while (true)
                {
                    System.Threading.Thread.Sleep(300);
                    if (!_isRecording || _isSelfPasting) continue;

                    List<string> closed = null;
                    lock (_lock)
                    {
                        foreach (KeyValuePair<string, IntPtr> kvp in _targetHwnds)
                        {
                            if (kvp.Value != IntPtr.Zero && (!IsWindow(kvp.Value) || !IsWindowVisible(kvp.Value)))
                            {
                                if (closed == null) closed = new List<string>();
                                closed.Add(kvp.Key);
                            }
                        }
                        if (closed != null)
                        {
                            foreach (string t in closed)
                            {
                                _targetHwnds.Remove(t);
                            }
                        }
                    }

                    if (closed != null)
                    {
                        foreach (string t in closed)
                        {
                            Console.WriteLine("{\"event\":\"target_closed\",\"target\":\"" + t + "\"}");
                        }
                    }
                }
            });

            Application.Run();
            UnhookWindowsHookEx(_hookID);
            if (_mouseHookID != IntPtr.Zero)
            {
                UnhookWindowsHookEx(_mouseHookID);
            }
            if (_winEventHook != IntPtr.Zero)
            {
                UnhookWinEvent(_winEventHook);
            }
        }

        private static IntPtr SetHook(LowLevelKeyboardProc proc)
        {
            using (Process curProcess = Process.GetCurrentProcess())
            using (ProcessModule curModule = curProcess.MainModule)
            {
                return SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(curModule.ModuleName), 0);
            }
        }

        private static IntPtr SetMouseHook(LowLevelMouseProc proc)
        {
            using (Process curProcess = Process.GetCurrentProcess())
            using (ProcessModule curModule = curProcess.MainModule)
            {
                return SetWindowsHookEx(WH_MOUSE_LL, proc, GetModuleHandle(curModule.ModuleName), 0);
            }
        }

        private static string GetClipboardText()
        {
            for (int attempt = 0; attempt < 5; attempt++)
            {
                if (OpenClipboard(IntPtr.Zero))
                {
                    try
                    {
                        IntPtr hData = GetClipboardData(CF_UNICODETEXT);
                        if (hData != IntPtr.Zero)
                        {
                            IntPtr pText = GlobalLock(hData);
                            if (pText != IntPtr.Zero)
                            {
                                try
                                {
                                    return Marshal.PtrToStringUni(pText);
                                }
                                finally
                                {
                                    GlobalUnlock(hData);
                                }
                            }
                        }
                        return null;
                    }
                    finally
                    {
                        CloseClipboard();
                    }
                }
                System.Threading.Thread.Sleep(5);
            }
            return null;
        }

        private static void ApplyPaste()
        {
            try
            {
                string clip = GetClipboardText();
                if (string.IsNullOrEmpty(clip)) return;

                if (clip.Length > 20000)
                {
                    clip = clip.Substring(clip.Length - 20000);
                }

                // Normalise carriage returns
                clip = clip.Replace("\r\n", "\n").Replace("\r", "\n");

                // If single line with trailing newline (e.g. copied line), strip trailing newline so command is not prematurely submitted
                string trimmed = clip.TrimEnd('\n');
                if (!trimmed.Contains("\n"))
                {
                    clip = trimmed;
                }

                lock (_buffer)
                {
                    if (_cursorPos < 0) _cursorPos = 0;
                    if (_cursorPos > _buffer.Length) _cursorPos = _buffer.Length;

                    if (_isForegroundNotepad)
                    {
                        _buffer.Insert(_cursorPos, clip);
                        _cursorPos += clip.Length;
                        NotifyUpdate();
                    }
                    else
                    {
                        int lastNl = clip.LastIndexOf('\n');
                        if (lastNl == -1)
                        {
                            _buffer.Insert(_cursorPos, clip);
                            _cursorPos += clip.Length;
                            NotifyUpdate();
                        }
                        else if (lastNl == clip.Length - 1)
                        {
                            // Trailing newline submitted the command
                            _buffer.Clear();
                            _cursorPos = 0;
                            NotifyAction("enter");
                        }
                        else
                        {
                            // Multiline paste into terminal: text after last newline remains in prompt
                            string remaining = clip.Substring(lastNl + 1);
                            _buffer.Clear();
                            _buffer.Append(remaining);
                            _cursorPos = remaining.Length;
                            NotifyUpdate();
                        }
                    }
                }
            }
            catch { }
        }

        private const string WordDelimiters = ";:,.[]{}()/\\|!?^&*-=+'\"`~@#$%<>";

        private static bool IsInWord(char c)
        {
            return !char.IsWhiteSpace(c) && WordDelimiters.IndexOf(c) < 0;
        }

        private static int GetBackwardWordPos(StringBuilder buf, int curPos)
        {
            if (curPos <= 0 || buf.Length == 0) return 0;
            int i = curPos - 1;
            if (i >= buf.Length) i = buf.Length - 1;

            // 1. Skip trailing whitespace and non-word characters (delimiters/punctuation)
            while (i >= 0 && !IsInWord(buf[i])) i--;

            // 2. Skip word characters backwards to the start of the word
            while (i >= 0 && IsInWord(buf[i])) i--;

            return Math.Max(0, i + 1);
        }

        private static int GetForwardWordPos(StringBuilder buf, int curPos)
        {
            if (curPos >= buf.Length) return buf.Length;
            int i = curPos;
            int n = buf.Length;

            // 1. If currently inside a word, skip to the end of the word
            while (i < n && IsInWord(buf[i])) i++;

            // 2. Skip following whitespace and non-word characters (delimiters/punctuation) to start of next word
            while (i < n && !IsInWord(buf[i])) i++;

            return Math.Min(n, i);
        }

        private static void DeleteWordBackward()
        {
            if (_cursorPos > 0 && _buffer.Length > 0)
            {
                int newPos = GetBackwardWordPos(_buffer, _cursorPos);
                int count = _cursorPos - newPos;
                if (count > 0)
                {
                    _buffer.Remove(newPos, count);
                    _cursorPos = newPos;
                    NotifyUpdate();
                }
            }
        }

        private static void DeleteWordForward()
        {
            if (_cursorPos < _buffer.Length)
            {
                int newPos = GetForwardWordPos(_buffer, _cursorPos);
                int count = newPos - _cursorPos;
                if (count > 0)
                {
                    _buffer.Remove(_cursorPos, count);
                    NotifyUpdate();
                }
            }
        }

        private static void MoveWordBackward()
        {
            _cursorPos = GetBackwardWordPos(_buffer, _cursorPos);
        }

        private static void MoveWordForward()
        {
            _cursorPos = GetForwardWordPos(_buffer, _cursorPos);
        }

        private static bool IsGcWindow(IntPtr hwnd)
        {
            try
            {
                StringBuilder titleSb = new StringBuilder(512);
                GetWindowText(hwnd, titleSb, titleSb.Capacity);
                string title = titleSb.ToString();
                if (title.IndexOf("GC -", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    title.IndexOf("GC //", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    title.IndexOf("gc-british-grammar-checker", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    return true;
                }
                return false;
            }
            catch { return false; }
        }

        private static bool ClassifyTarget(IntPtr hwnd, out string targetId, out string targetName, out bool isEditor)
        {
            targetId = "terminal";
            targetName = "Terminal";
            isEditor = false;

            try
            {
                if (hwnd == IntPtr.Zero || !IsWindow(hwnd)) return false;

                StringBuilder classSb = new StringBuilder(256);
                GetClassName(hwnd, classSb, classSb.Capacity);
                string className = classSb.ToString();

                // Reject ConPTY PseudoConsoleWindow and IME/helper windows
                if (string.Equals(className, "PseudoConsoleWindow", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(className, "IME", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(className, "MSCTFIME UI", StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }

                // Reject zero-sized invisible helper windows (unless minimized/iconic)
                if (!IsIconic(hwnd))
                {
                    RECT winRect;
                    if (GetWindowRect(hwnd, out winRect))
                    {
                        if ((winRect.Right - winRect.Left) <= 10 || (winRect.Bottom - winRect.Top) <= 10)
                        {
                            return false;
                        }
                    }
                }

                uint pid;
                GetWindowThreadProcessId(hwnd, out pid);
                if (pid == 0) return false;

                string procName = "";
                try
                {
                    using (Process proc = Process.GetProcessById((int)pid))
                    {
                        procName = proc.ProcessName;
                    }
                }
                catch { }

                StringBuilder titleSb = new StringBuilder(512);
                GetWindowText(hwnd, titleSb, titleSb.Capacity);
                string title = titleSb.ToString();

                // Explicitly ignore GC itself
                if (IsGcWindow(hwnd))
                {
                    return false;
                }

                bool isBrowser = string.Equals(procName, "chrome", StringComparison.OrdinalIgnoreCase) ||
                                 string.Equals(procName, "msedge", StringComparison.OrdinalIgnoreCase) ||
                                 string.Equals(procName, "firefox", StringComparison.OrdinalIgnoreCase) ||
                                 string.Equals(procName, "brave", StringComparison.OrdinalIgnoreCase) ||
                                 string.Equals(procName, "opera", StringComparison.OrdinalIgnoreCase) ||
                                 string.Equals(procName, "vivaldi", StringComparison.OrdinalIgnoreCase);

                if (isBrowser)
                {
                    // A browser is ONLY a target if it is explicitly running CyberTerminal
                    if (title.IndexOf("CyberTerminal", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        targetId = "terminal";
                        targetName = "CyberTerminal";
                        isEditor = false;
                        return true;
                    }
                    // Never allow regular browser tabs to match generic "Terminal" or "Notes" rules!
                    return false;
                }

                // Explicitly reject code editors, IDEs, office suites, file managers, chats, and other software
                // so GC NEVER intercepts typing in general software!
                if (string.Equals(procName, "code", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "cursor", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "windsurf", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "devenv", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "idea64", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "pycharm64", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "webstorm64", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "sublime_text", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "notepad++", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "explorer", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "slack", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "discord", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "teams", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "wechat", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "qq", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "word", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "winword", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "excel", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "powerpnt", StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }

                // 1. Target: Notepad (Win11 / Classic) - ONLY match genuine notepad process
                if (string.Equals(procName, "notepad", StringComparison.OrdinalIgnoreCase))
                {
                    targetId = "notes";
                    targetName = "Notepad";
                    isEditor = true;
                    return true;
                }

                // 2. Target: CyberTerminal (Desktop app or Web tab in Browser)
                if (procName.IndexOf("cyberterminal", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    title.IndexOf("CyberTerminal", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    targetId = "terminal";
                    targetName = "CyberTerminal";
                    isEditor = false;
                    return true;
                }

                // 3. Target: Terminal Windows (Windows Terminal, CMD, PowerShell, Git Bash, etc.)
                bool isTerminalProc =
                    string.Equals(procName, "WindowsTerminal", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "wt", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "cmd", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "powershell", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "pwsh", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "conhost", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "OpenConsole", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "alacritty", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "warp", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "wezterm-gui", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "wezterm", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "mintty", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "bash", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "sh", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "zsh", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "git-bash", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "kitty", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(procName, "ghostty", StringComparison.OrdinalIgnoreCase);

                if (isTerminalProc)
                {
                    targetId = "terminal";
                    targetName = "Terminal";
                    isEditor = false;
                    return true;
                }

                return false;
            }
            catch
            {
                return false;
            }
        }

        private static bool CheckIfForegroundIsTarget(out string targetId, out string targetName, out bool isEditor)
        {
            targetId = _activeTargetId;
            targetName = _activeTargetName;
            isEditor = _isForegroundNotepad;

            IntPtr fg = GetForegroundWindow();
            if (fg == IntPtr.Zero) return false;

            int now = Environment.TickCount;
            if (fg == _cachedHwnd && (now - _cachedTick) < 400 && (now - _cachedTick) >= 0)
            {
                targetId = _cachedTargetId;
                targetName = _cachedTargetName;
                isEditor = _cachedIsEditor;
                return _cachedIsTarget;
            }

            _cachedHwnd = fg;
            _cachedTick = now;
            _cachedIsTarget = ClassifyTarget(fg, out _cachedTargetId, out _cachedTargetName, out _cachedIsEditor);
            targetId = _cachedTargetId;
            targetName = _cachedTargetName;
            isEditor = _cachedIsEditor;
            return _cachedIsTarget;
        }

        private static void CheckForegroundWindow(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return;
            if (IsGcWindow(hwnd))
            {
                _wasLastForegroundTarget = true;
                return;
            }

            string targetId;
            string targetName;
            bool isEditor;
            bool isTarget = ClassifyTarget(hwnd, out targetId, out targetName, out isEditor);

            if (isTarget)
            {
                lock (_lock)
                {
                    _activeTargetId = targetId;
                    _activeTargetName = targetName;
                    _isForegroundNotepad = isEditor;
                    _targetHwnds[targetId] = hwnd;
                }
                _wasLastForegroundTarget = true;
                NotifyFocus(targetId, targetName);
            }
            else
            {
                if (_wasLastForegroundTarget)
                {
                    _wasLastForegroundTarget = false;
                    NotifyBlur();
                }
            }
        }

        private static void WinEventProc(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime)
        {
            if (eventType == EVENT_SYSTEM_FOREGROUND)
            {
                CheckForegroundWindow(hwnd);
            }
        }

        private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (_isSelfPasting)
            {
                return CallNextHookEx(_hookID, nCode, wParam, lParam);
            }

            if (nCode >= 0 && (wParam == (IntPtr)WM_KEYDOWN || wParam == (IntPtr)WM_SYSKEYDOWN))
            {
                int vkCode = Marshal.ReadInt32(lParam);
                Keys key = (Keys)vkCode;

                bool isCtrl = (GetKeyState((int)Keys.ControlKey) & 0x80) != 0;
                bool isAlt = (GetKeyState((int)Keys.Menu) & 0x80) != 0;
                bool isWin = ((GetKeyState((int)Keys.LWin) & 0x80) != 0) || ((GetKeyState((int)Keys.RWin) & 0x80) != 0);

                // CRITICAL FIX: Any key press while the Windows key is held (e.g. Win + E, Win + R, Win + D)
                // must NEVER be recorded as typing or trigger GC!
                if (isWin)
                {
                    return CallNextHookEx(_hookID, nCode, wParam, lParam);
                }

                // Ignore hotkey triggering combinations (e.g. Ctrl + Alt + X or Ctrl + Alt + Z)
                if (isCtrl && isAlt && (key == Keys.X || key == Keys.Z))
                {
                    return CallNextHookEx(_hookID, nCode, wParam, lParam);
                }

                // Ignore standalone modifiers
                if (key == Keys.ShiftKey || key == Keys.LShiftKey || key == Keys.RShiftKey ||
                    key == Keys.ControlKey || key == Keys.LControlKey || key == Keys.RControlKey ||
                    key == Keys.Menu || key == Keys.LMenu || key == Keys.RMenu ||
                    key == Keys.LWin || key == Keys.RWin ||
                    key == Keys.Capital || key == Keys.NumLock || key == Keys.Scroll)
                {
                    return CallNextHookEx(_hookID, nCode, wParam, lParam);
                }

                if (_isRecording)
                {
                    // Strict filtering: only record typing if active window is Terminal, CyberTerminal, or Notepad
                    string targetId;
                    string targetName;
                    bool isEditor;
                    if (!CheckIfForegroundIsTarget(out targetId, out targetName, out isEditor))
                    {
                        return CallNextHookEx(_hookID, nCode, wParam, lParam);
                    }

                    lock (_lock)
                    {
                        _targetHwnds[targetId] = _cachedHwnd;
                        if (_activeTargetId != targetId)
                        {
                            _activeTargetId = targetId;
                            _activeTargetName = targetName;
                            _isForegroundNotepad = isEditor;
                            NotifyFocus(targetId, targetName);
                        }
                        _wasLastForegroundTarget = true;

                        if (_cursorPos < 0) _cursorPos = 0;
                        if (_cursorPos > _buffer.Length) _cursorPos = _buffer.Length;

                        // -------------------------------------------------------------
                        // TERMINAL CONTROL HOTKEYS (when Ctrl is held)
                        // -------------------------------------------------------------
                        if (isCtrl)
                        {
                            // Ctrl + Z: Undo action in Review Mode
                            if (key == Keys.Z)
                            {
                                NotifyAction("undo");
                            }
                            // Ctrl + V or Ctrl + Shift + V: Paste from clipboard
                            else if (key == Keys.V)
                            {
                                ApplyPaste();
                            }
                            // Ctrl + Enter: Execute / submit prompt
                            else if (key == Keys.Enter)
                            {
                                _buffer.Clear();
                                _cursorPos = 0;
                                NotifyAction("enter");
                            }
                            // Ctrl + U: Unix Line Kill (delete all text from cursor back to start of line)
                            else if (key == Keys.U)
                            {
                                int lineStart = _cursorPos - 1;
                                while (lineStart >= 0 && _buffer[lineStart] != '\n' && _buffer[lineStart] != '\r') lineStart--;
                                int start = lineStart + 1;
                                int count = _cursorPos - start;
                                if (count > 0)
                                {
                                    _buffer.Remove(start, count);
                                    _cursorPos = start;
                                    NotifyUpdate();
                                }
                            }
                            // Ctrl + K: Kill forward to end of line
                            else if (key == Keys.K)
                            {
                                int lineEnd = _cursorPos;
                                while (lineEnd < _buffer.Length && _buffer[lineEnd] != '\n' && _buffer[lineEnd] != '\r') lineEnd++;
                                int count = lineEnd - _cursorPos;
                                if (count > 0)
                                {
                                    _buffer.Remove(_cursorPos, count);
                                    NotifyUpdate();
                                }
                            }
                            // Ctrl + W or Ctrl + Backspace: Delete preceding word
                            else if (key == Keys.W || key == Keys.Back)
                            {
                                DeleteWordBackward();
                            }
                            // Ctrl + Delete: Delete following word
                            else if (key == Keys.Delete)
                            {
                                DeleteWordForward();
                            }
                            // Ctrl + A: Move cursor to start of line
                            else if (key == Keys.A)
                            {
                                int lineStart = _cursorPos - 1;
                                while (lineStart >= 0 && _buffer[lineStart] != '\n' && _buffer[lineStart] != '\r') lineStart--;
                                _cursorPos = lineStart + 1;
                            }
                            // Ctrl + E: Move cursor to end of line
                            else if (key == Keys.E)
                            {
                                int lineEnd = _cursorPos;
                                while (lineEnd < _buffer.Length && _buffer[lineEnd] != '\n' && _buffer[lineEnd] != '\r') lineEnd++;
                                _cursorPos = lineEnd;
                            }
                            // Ctrl + Left: Move backward one word
                            else if (key == Keys.Left)
                            {
                                MoveWordBackward();
                            }
                            // Ctrl + Right: Move forward one word
                            else if (key == Keys.Right)
                            {
                                MoveWordForward();
                            }
                            // Ctrl + D: Delete char at cursor
                            else if (key == Keys.D)
                            {
                                if (_cursorPos < _buffer.Length)
                                {
                                    _buffer.Remove(_cursorPos, 1);
                                    NotifyUpdate();
                                }
                            }
                        }
                        // -------------------------------------------------------------
                        // ALT CONTROL HOTKEYS (when Alt is held, but not Ctrl)
                        // -------------------------------------------------------------
                        else if (isAlt)
                        {
                            // Alt + Backspace or Alt + W: Delete preceding word (word-by-word backward deletion)
                            if (key == Keys.Back || key == Keys.W)
                            {
                                DeleteWordBackward();
                            }
                            // Alt + Delete or Alt + D: Delete following word (word-by-word forward deletion)
                            else if (key == Keys.Delete || key == Keys.D)
                            {
                                DeleteWordForward();
                            }
                            // Alt + Left or Alt + B: Move backward one word
                            else if (key == Keys.Left || key == Keys.B)
                            {
                                MoveWordBackward();
                            }
                            // Alt + Right or Alt + F: Move forward one word
                            else if (key == Keys.Right || key == Keys.F)
                            {
                                MoveWordForward();
                            }
                        }
                        // -------------------------------------------------------------
                        // STANDARD TYPING & NAVIGATION (neither Ctrl nor Alt is held)
                        // -------------------------------------------------------------
                        else
                        {
                            bool isShift = (GetKeyState((int)Keys.ShiftKey) & 0x80) != 0;
                            // Shift + Insert: Classic terminal paste
                            if (key == Keys.Insert && isShift)
                            {
                                ApplyPaste();
                            }
                            else if (key == Keys.Back)
                            {
                                if (_cursorPos > 0)
                                {
                                    _cursorPos--;
                                    _buffer.Remove(_cursorPos, 1);
                                    NotifyUpdate();
                                }
                            }
                            else if (key == Keys.Delete)
                            {
                                if (_cursorPos < _buffer.Length)
                                {
                                    _buffer.Remove(_cursorPos, 1);
                                    NotifyUpdate();
                                }
                            }
                            else if (key == Keys.Left)
                            {
                                if (_cursorPos > 0) _cursorPos--;
                            }
                            else if (key == Keys.Right)
                            {
                                if (_cursorPos < _buffer.Length) _cursorPos++;
                            }
                            else if (key == Keys.Up)
                            {
                                if (_isForegroundNotepad || _buffer.ToString().IndexOf('\n') >= 0)
                                {
                                    int curLineStart = _cursorPos - 1;
                                    while (curLineStart >= 0 && _buffer[curLineStart] != '\n' && _buffer[curLineStart] != '\r') curLineStart--;
                                    curLineStart++;
                                    int col = _cursorPos - curLineStart;

                                    int prevLineEnd = curLineStart - 1;
                                    while (prevLineEnd >= 0 && (_buffer[prevLineEnd] == '\n' || _buffer[prevLineEnd] == '\r')) prevLineEnd--;
                                    if (prevLineEnd >= 0)
                                    {
                                        int prevLineStart = prevLineEnd;
                                        while (prevLineStart >= 0 && _buffer[prevLineStart] != '\n' && _buffer[prevLineStart] != '\r') prevLineStart--;
                                        prevLineStart++;
                                        int prevLineLen = prevLineEnd - prevLineStart + 1;
                                        _cursorPos = prevLineStart + Math.Min(col, Math.Max(0, prevLineLen));
                                    }
                                    else
                                    {
                                        _cursorPos = 0;
                                    }
                                }
                            }
                            else if (key == Keys.Down)
                            {
                                if (_isForegroundNotepad || _buffer.ToString().IndexOf('\n') >= 0)
                                {
                                    int curLineStart = _cursorPos - 1;
                                    while (curLineStart >= 0 && _buffer[curLineStart] != '\n' && _buffer[curLineStart] != '\r') curLineStart--;
                                    curLineStart++;
                                    int col = _cursorPos - curLineStart;

                                    int curLineEnd = _cursorPos;
                                    while (curLineEnd < _buffer.Length && _buffer[curLineEnd] != '\n' && _buffer[curLineEnd] != '\r') curLineEnd++;

                                    int nextLineStart = curLineEnd;
                                    while (nextLineStart < _buffer.Length && (_buffer[nextLineStart] == '\n' || _buffer[nextLineStart] == '\r')) nextLineStart++;

                                    if (nextLineStart < _buffer.Length)
                                    {
                                        int nextLineEnd = nextLineStart;
                                        while (nextLineEnd < _buffer.Length && _buffer[nextLineEnd] != '\n' && _buffer[nextLineEnd] != '\r') nextLineEnd++;
                                        int nextLineLen = nextLineEnd - nextLineStart;
                                        _cursorPos = nextLineStart + Math.Min(col, Math.Max(0, nextLineLen));
                                    }
                                    else
                                    {
                                        _cursorPos = _buffer.Length;
                                    }
                                }
                            }
                            else if (key == Keys.Home)
                            {
                                int lineStart = _cursorPos - 1;
                                while (lineStart >= 0 && _buffer[lineStart] != '\n' && _buffer[lineStart] != '\r') lineStart--;
                                _cursorPos = lineStart + 1;
                            }
                            else if (key == Keys.End)
                            {
                                int lineEnd = _cursorPos;
                                while (lineEnd < _buffer.Length && _buffer[lineEnd] != '\n' && _buffer[lineEnd] != '\r') lineEnd++;
                                _cursorPos = lineEnd;
                            }
                            else if (key == Keys.Enter)
                            {
                                if (isShift || _isForegroundNotepad)
                                {
                                    _buffer.Insert(_cursorPos, "\n");
                                    _cursorPos++;
                                    NotifyUpdate();
                                }
                                else
                                {
                                    // In Terminal / CyberTerminal, Enter submits the command line.
                                    _buffer.Clear();
                                    _cursorPos = 0;
                                    NotifyAction("enter");
                                }
                            }
                            else if (key == Keys.Space)
                            {
                                _buffer.Insert(_cursorPos, " ");
                                _cursorPos++;
                                NotifyUpdate();
                            }
                            else if (key == Keys.Tab)
                            {
                                _buffer.Insert(_cursorPos, "\t");
                                _cursorPos++;
                                NotifyUpdate();
                            }
                            else if (key == Keys.Escape)
                            {
                                // In terminal, Escape can clear prompt in some shells
                            }
                            else
                            {
                                byte[] keyState = new byte[256];
                                GetKeyboardState(keyState);

                                keyState[(int)Keys.ShiftKey] = (byte)((GetKeyState((int)Keys.ShiftKey) & 0x80) != 0 ? 0x80 : 0);
                                keyState[(int)Keys.Capital] = (byte)((GetKeyState((int)Keys.Capital) & 0x01) != 0 ? 0x01 : 0);

                                StringBuilder sb = new StringBuilder(10);
                                int res = ToUnicode((uint)vkCode, 0, keyState, sb, sb.Capacity, 0);
                                if (res > 0)
                                {
                                    string s = sb.ToString();
                                    if (!char.IsControl(s[0]) || s[0] == '\r' || s[0] == '\n' || s[0] == '\t')
                                    {
                                        _buffer.Insert(_cursorPos, s);
                                        _cursorPos += s.Length;
                                        NotifyUpdate();
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return CallNextHookEx(_hookID, nCode, wParam, lParam);
        }

        private static IntPtr HookCallbackMouse(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0 && (wParam == (IntPtr)WM_RBUTTONUP || wParam == (IntPtr)WM_MBUTTONUP))
            {
                string targetId;
                string targetName;
                bool isEditor;
                if (_isRecording && CheckIfForegroundIsTarget(out targetId, out targetName, out isEditor) && !isEditor)
                {
                    IntPtr fg = GetForegroundWindow();
                    if (fg != IntPtr.Zero)
                    {
                        RECT clientRect;
                        if (GetClientRect(fg, out clientRect))
                        {
                            MSLLHOOKSTRUCT hookStruct = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                            POINT pt = hookStruct.pt;
                            ScreenToClient(fg, ref pt);
                            if (pt.x >= 0 && pt.y >= 0 && pt.x <= clientRect.Right && pt.y <= clientRect.Bottom)
                            {
                                uint seqBefore = GetClipboardSequenceNumber();
                                System.Threading.ThreadPool.QueueUserWorkItem((state) =>
                                {
                                    System.Threading.Thread.Sleep(60);
                                    uint seqAfter = GetClipboardSequenceNumber();
                                    // If sequence number didn't change, right/middle click was a PASTE (not a copy)
                                    if (seqAfter == seqBefore)
                                    {
                                        ApplyPaste();
                                    }
                                });
                            }
                        }
                    }
                }
            }
            return CallNextHookEx(_mouseHookID, nCode, wParam, lParam);
        }

        private static void NotifyUpdate()
        {
            StringBuilder buf = GetBufferForTarget(_activeTargetId);
            string text = buf.ToString();
            int len = text.Length;
            int words = CountWords(text);
            string escaped = EscapeJson(text);
            Console.WriteLine("{\"event\":\"update\",\"target\":\"" + _activeTargetId + "\",\"targetName\":\"" + _activeTargetName + "\",\"text\":\"" + escaped + "\",\"length\":" + len + ",\"words\":" + words + "}");
        }

        private static void NotifyAction(string action)
        {
            Console.WriteLine("{\"event\":\"action\",\"target\":\"" + _activeTargetId + "\",\"targetName\":\"" + _activeTargetName + "\",\"action\":\"" + action + "\",\"text\":\"\",\"length\":0,\"words\":0}");
        }

        private static void NotifyFocus(string targetId, string targetName)
        {
            Console.WriteLine("{\"event\":\"focus\",\"target\":\"" + targetId + "\",\"targetName\":\"" + targetName + "\"}");
        }

        private static void NotifyBlur()
        {
            Console.WriteLine("{\"event\":\"blur\"}");
        }

        private static int CountWords(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) return 0;
            string[] parts = text.Split(new char[] { ' ', '\t', '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries);
            return parts.Length;
        }

        private static string EscapeJson(string s)
        {
            if (s == null) return "";
            StringBuilder sb = new StringBuilder();
            foreach (char c in s)
            {
                switch (c)
                {
                    case '\\': sb.Append("\\\\"); break;
                    case '\"': sb.Append("\\\""); break;
                    case '\b': sb.Append("\\b"); break;
                    case '\f': sb.Append("\\f"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < ' ')
                        {
                            sb.AppendFormat("\\u{0:x4}", (int)c);
                        }
                        else
                        {
                            sb.Append(c);
                        }
                        break;
                }
            }
            return sb.ToString();
        }

        private static void ForceForegroundWindow(IntPtr hWnd)
        {
            if (hWnd == IntPtr.Zero || !IsWindow(hWnd)) return;
            IntPtr foreWnd = GetForegroundWindow();
            if (foreWnd == hWnd) return;

            if (IsIconic(hWnd))
            {
                ShowWindow(hWnd, 9); // SW_RESTORE if minimized
            }
            else if (!IsWindowVisible(hWnd))
            {
                ShowWindow(hWnd, 5); // SW_SHOW only if currently hidden
            }

            BringWindowToTop(hWnd);
            SetForegroundWindow(hWnd);
            if (GetForegroundWindow() != hWnd)
            {
                SwitchToThisWindow(hWnd, true);
            }
        }

        private static IntPtr FindTargetWindow(string targetId)
        {
            IntPtr found = IntPtr.Zero;
            EnumWindows((hWnd, lParam) =>
            {
                if (!IsWindowVisible(hWnd)) return true;
                string tId, tName;
                bool isEd;
                if (ClassifyTarget(hWnd, out tId, out tName, out isEd) && tId == targetId)
                {
                    found = hWnd;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            return found;
        }

        private static void ActivateAndPasteToTarget(string targetId)
        {
            IntPtr targetHwnd = IntPtr.Zero;

            // 1. If current foreground window is already a target window matching targetId, use it directly!
            IntPtr fg = GetForegroundWindow();
            if (fg != IntPtr.Zero && !IsGcWindow(fg) && IsWindowVisible(fg))
            {
                string curTId, curTName;
                bool curEd;
                if (ClassifyTarget(fg, out curTId, out curTName, out curEd) && curTId == targetId)
                {
                    targetHwnd = fg;
                }
            }

            // 2. Otherwise check cached target window (must still be valid and visible)
            if (targetHwnd == IntPtr.Zero)
            {
                lock (_lock)
                {
                    if (_targetHwnds.ContainsKey(targetId) && IsWindow(_targetHwnds[targetId]) && IsWindowVisible(_targetHwnds[targetId]))
                    {
                        targetHwnd = _targetHwnds[targetId];
                    }
                }
            }

            // 3. Fallback to searching top-level windows
            if (targetHwnd == IntPtr.Zero || !IsWindow(targetHwnd) || !IsWindowVisible(targetHwnd))
            {
                targetHwnd = FindTargetWindow(targetId);
            }

            if (targetHwnd == IntPtr.Zero)
            {
                try
                {
                    if (targetId == "notes")
                    {
                        Process.Start("notepad.exe");
                        System.Threading.Thread.Sleep(350);
                        targetHwnd = FindTargetWindow(targetId);
                    }
                    else if (targetId == "terminal")
                    {
                        try { Process.Start("wt.exe"); } catch { Process.Start("powershell.exe"); }
                        System.Threading.Thread.Sleep(450);
                        targetHwnd = FindTargetWindow(targetId);
                    }
                }
                catch { }
            }

            if (targetHwnd != IntPtr.Zero)
            {
                lock (_lock)
                {
                    _targetHwnds[targetId] = targetHwnd;
                }

                _isSelfPasting = true;
                try
                {
                    const int KEYEVENTF_KEYUP = 0x0002;
                    const byte VK_SHIFT = 0x10;
                    const byte VK_CONTROL = 0x11;
                    const byte VK_MENU = 0x12; // Alt key
                    const byte VK_V = 0x56;
                    const byte VK_X = 0x58;

                    // Step A: Wait up to 2000ms for user to physically release Ctrl, Alt, Shift, and X
                    // before switching focus or sending Ctrl+V. Never synthesize fake Alt/X/Shift key-ups,
                    // which can trigger third-party window-hider hooks on the active window.
                    int waited = 0;
                    while (waited < 2000)
                    {
                        bool altPressed = (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;
                        bool ctrlPressed = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
                        bool shiftPressed = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
                        bool xPressed = (GetAsyncKeyState(VK_X) & 0x8000) != 0;
                        if (!altPressed && !ctrlPressed && !shiftPressed && !xPressed) break;
                        System.Threading.Thread.Sleep(15);
                        waited += 15;
                    }

                    // Step B: Activate the linked target window cleanly
                    if (GetForegroundWindow() != targetHwnd)
                    {
                        ForceForegroundWindow(targetHwnd);
                        System.Threading.Thread.Sleep(60);
                    }

                    // Step C: Send clean Ctrl + V (paste without submit/Enter)
                    keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
                    System.Threading.Thread.Sleep(20);
                    keybd_event(VK_V, 0, 0, UIntPtr.Zero);
                    System.Threading.Thread.Sleep(30);
                    keybd_event(VK_V, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
                    System.Threading.Thread.Sleep(20);
                    keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);

                    // Step D: Safety check - if any external hook hid the target window, restore its visibility immediately
                    System.Threading.Thread.Sleep(50);
                    if (IsWindow(targetHwnd) && !IsWindowVisible(targetHwnd))
                    {
                        ShowWindow(targetHwnd, 5);
                        BringWindowToTop(targetHwnd);
                        SetForegroundWindow(targetHwnd);
                    }

                    Console.WriteLine("{\"event\":\"pasted\",\"target\":\"" + targetId + "\"}");
                }
                finally
                {
                    // Delay slightly before releasing _isSelfPasting so queued hook events are bypassed
                    System.Threading.Thread.Sleep(60);
                    _isSelfPasting = false;
                }
            }
        }
    }
}
