const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const EventEmitter = require('events');

class KeyMonitorManager extends EventEmitter {
  constructor(exePath = null) {
    super();
    const defaultBin = process.platform === 'darwin' ? 'KeyMonitor_mac' : 'KeyMonitor.exe';
    this.exePath = exePath || path.join(__dirname, '..', 'bin', defaultBin);
    this.process = null;
    this.isRecording = false;
    this.stopCallbacks = [];
  }

  start() {
    if (!fs.existsSync(this.exePath)) {
      throw new Error(`KeyMonitor binary not found at ${this.exePath}`);
    }

    if (process.platform === 'darwin') {
      try {
        fs.chmodSync(this.exePath, '755');
      } catch (e) {}
    }

    this.process = spawn(this.exePath, [], {
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: process.platform === 'win32'
    });

    let stdoutBuffer = '';

    this.process.stdout.on('data', (chunk) => {
      stdoutBuffer += chunk.toString('utf8');
      const lines = stdoutBuffer.split('\n');
      stdoutBuffer = lines.pop(); // keep partial line

      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
          const data = JSON.parse(trimmed);
          this.handleEvent(data);
        } catch (e) {
          // ignore non-json log lines
        }
      }
    });

    this.process.stderr.on('data', (chunk) => {
      console.error('[KeyMonitor stderr]', chunk.toString());
    });

    this.process.on('close', (code) => {
      const wasRecording = this.isRecording;
      this.process = null;
      this.isRecording = false;
      this.emit('closed', code);
      if (!this.isDestroyed) {
        setTimeout(() => {
          if (!this.isDestroyed && !this.process) {
            try {
              this.start();
              if (wasRecording) {
                this.startRecording();
              }
            } catch (e) {}
          }
        }, 300);
      }
    });

    this.process.on('error', (err) => {
      this.emit('error', err);
    });
  }

  handleEvent(data) {
    if (data.event === 'started') {
      this.isRecording = true;
      this.emit('started');
    } else if (data.event === 'update') {
      this.emit('update', {
        target: data.target || 'terminal',
        targetName: data.targetName || 'Terminal',
        text: data.text || '',
        length: data.length,
        words: data.words
      });
    } else if (data.event === 'stopped') {
      this.isRecording = false;
      const text = data.text || '';
      this.emit('stopped', {
        target: data.target || 'terminal',
        text
      });

      // Resolve any pending stop callbacks
      while (this.stopCallbacks.length > 0) {
        const cb = this.stopCallbacks.shift();
        cb(text);
      }
    } else if (data.event === 'cleared') {
      this.emit('cleared', { target: data.target || 'terminal' });
    } else if (data.event === 'action') {
      this.emit('action', {
        target: data.target || 'terminal',
        targetName: data.targetName || 'Terminal',
        action: data.action
      });
    } else if (data.event === 'focus') {
      this.emit('focus', {
        target: data.target || 'terminal',
        targetName: data.targetName || 'Terminal'
      });
    } else if (data.event === 'blur') {
      this.emit('blur');
    } else if (data.event === 'pasted') {
      this.emit('pasted', { target: data.target || 'terminal' });
    } else if (data.event === 'target_closed') {
      this.emit('target_closed', { target: data.target || 'terminal' });
    } else if (data.event === 'status') {
      this.emit('status', data);
    }
  }

  pasteToTarget(target = null) {
    if (this.process) {
      try {
        if (target) {
          this.process.stdin.write(`PASTE ${target}\n`);
        } else {
          this.process.stdin.write('PASTE\n');
        }
      } catch (e) {}
    }
  }

  startRecording() {
    if (!this.process) this.start();
    this.isRecording = true;
    this.process.stdin.write('START\n');
  }

  clearBuffer(target = null) {
    if (this.process && this.isRecording) {
      try {
        if (target) {
          this.process.stdin.write(`CLEAR ${target}\n`);
        } else {
          this.process.stdin.write('CLEAR\n');
        }
      } catch (e) {}
    }
  }

  stopRecording() {
    return new Promise((resolve) => {
      if (!this.process || !this.isRecording) {
        resolve('');
        return;
      }
      this.stopCallbacks.push(resolve);
      this.process.stdin.write('STOP\n');
    });
  }

  toggleRecording() {
    if (this.isRecording) {
      return this.stopRecording();
    } else {
      this.startRecording();
      return Promise.resolve(null);
    }
  }

  destroy() {
    this.isDestroyed = true;
    if (this.process) {
      try {
        this.process.stdin.write('EXIT\n');
        setTimeout(() => {
          if (this.process && !this.process.killed) {
            this.process.kill();
          }
        }, 1000);
      } catch (e) {}
    }
  }
}

module.exports = { KeyMonitorManager };
