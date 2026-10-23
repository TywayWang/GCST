const http = require('http');

class OllamaClient {
  constructor(baseUrl = 'http://127.0.0.1:11434', preferredModel = 'gemma4:e4b', preferredDialect = 'en-GB') {
    this.baseUrl = baseUrl;
    this.preferredModel = preferredModel;
    this.activeModel = preferredModel;
    this.activeDialect = preferredDialect || 'en-GB';
  }

  getPromptConfig(dialect) {
    const commonRules = `
CRITICAL RULES FOR "issues":
- The "issues" array must contain all mistakes, including spelling mistakes, typos, non-words, nonsensical gibberish, grammar errors, dialect conventions, and punctuation flaws.
- Every word or token that is not a recognized, valid English word (such as typos, keyboard mash, or nonsensical gibberish like "sjap", "sajpa", "opjsad", "saas", "teh", "recieve") MUST be flagged in "issues" as "spelling" or "vocabulary". Suggest the closest valid English word as "replacement", or correct it appropriately.
- NEVER treat non-words, typos, or nonsensical gibberish as correct English.
- The "issues" array must ONLY contain actual mistakes where "original" strictly differs from "replacement".
- If a word or phrase is ALREADY correct (for example, if a word is already correct according to the chosen dialect, or a valid term needs no edit), DO NOT include it in "issues".
- NEVER output an issue where "original" equals "replacement".
- If and only if the text consists entirely of valid, real English words with completely correct grammar, spelling, and punctuation, return "issues": [].`;

    if (dialect === 'en-US') {
      return {
        dialectName: 'American English (en-US)',
        instruction: 'Please review and correct the following text into American English (en-US):',
        systemPrompt: `You are an expert American English editor and proofreader (en-US).
Your task is to thoroughly review the user's text and correct:
1. Spelling, typos, and non-words: Any word that is not a recognized, valid English word (including typos, misspellings, keyboard mash, or nonsensical tokens) MUST be flagged and corrected to a valid English word.
2. American English spelling conventions (e.g. -or instead of -our like color, -er instead of -re like center, -ize instead of -ise like realize, traveled).
3. Grammatical errors, subject-verb agreement, and natural American phrasing.
4. Standard American English punctuation and sentence flow.
${commonRules}

You MUST respond strictly with a valid JSON object matching this schema:
{
  "original": "exact original text",
  "corrected": "complete corrected text in American English",
  "issues": [
    {
      "original": "the exact word or phrase with issue",
      "replacement": "American English replacement",
      "type": "spelling" | "grammar" | "vocabulary" | "punctuation",
      "explanation": "concise explanation referencing American English convention"
    }
  ],
  "summary": "a brief 1-sentence summary"
}
Do not output markdown code blocks. Output raw JSON only.`
      };
    } else if (dialect === 'en-AU') {
      return {
        dialectName: 'Australian English (en-AU)',
        instruction: 'Please review and correct the following text into Australian English (en-AU):',
        systemPrompt: `You are an expert Australian English editor and proofreader (en-AU).
Your task is to thoroughly review the user's text and correct:
1. Spelling, typos, and non-words: Any word that is not a recognized, valid English word (including typos, misspellings, keyboard mash, or nonsensical tokens) MUST be flagged and corrected to a valid English word.
2. Australian English spelling conventions (Commonwealth spelling: -our like colour, -re like centre, -ise like organise, licence for noun, travelled).
3. Australian English vocabulary and phrasing (e.g. footpath instead of sidewalk, lift instead of elevator, rubbish instead of trash, petrol instead of gas).
4. Standard Australian English grammar and punctuation.
${commonRules}

You MUST respond strictly with a valid JSON object matching this schema:
{
  "original": "exact original text",
  "corrected": "complete corrected text in Australian English",
  "issues": [
    {
      "original": "the exact word or phrase with issue",
      "replacement": "Australian English replacement",
      "type": "spelling" | "grammar" | "vocabulary" | "punctuation",
      "explanation": "concise explanation referencing Australian English convention"
    }
  ],
  "summary": "a brief 1-sentence summary"
}
Do not output markdown code blocks. Output raw JSON only.`
      };
    } else if (dialect === 'en-CN') {
      return {
        dialectName: 'Chinglish (en-CN)',
        instruction: 'Please transform/correct the following text into humorous Chinglish (en-CN):',
        systemPrompt: `You are a humorous Chinglish (en-CN) specialist. This is a playful, entertaining "Chinglish Fun Mode".
Your task is to transform or review the user's text into iconic, hilarious, Chinese-style English (Chinglish):
1. Chinese literal translation idioms (e.g., "people mountain people sea" for crowded, "give you some color to see see" for teach a lesson, "long time no see", "good good study, day day up", "no can do", "add oil!", "you have two brushstrokes", "laugh die me").
2. Direct translation structures (e.g., "open the light", "close the aircon", "eat medicine", "play my phone", "I very like it", "wait me a minute").
3. Retain the core meaning while giving it unforgettable Chinglish charm!
${commonRules}

You MUST respond strictly with a valid JSON object matching this schema:
{
  "original": "exact original text",
  "corrected": "humorously transformed Chinglish text",
  "issues": [
    {
      "original": "the exact word or phrase transformed",
      "replacement": "Chinglish replacement",
      "type": "vocabulary" | "grammar",
      "explanation": "humorous explanation of the Chinese idiom or Chinglish logic behind it"
    }
  ],
  "summary": "a witty 1-sentence summary in Chinglish spirit"
}
Do not output markdown code blocks. Output raw JSON only.`
      };
    } else {
      // Default en-GB
      return {
        dialectName: 'British English (en-GB)',
        instruction: 'Please review and correct the following text into British English (en-GB):',
        systemPrompt: `You are an expert British English editor and proofreader (en-GB).
Your task is to thoroughly review the user's text and correct:
1. Spelling, typos, and non-words: Any word that is not a recognized, valid English word (including typos, misspellings, keyboard mash, or nonsensical tokens) MUST be flagged and corrected to a valid English word.
2. British English spelling conventions (e.g. -our instead of -or like colour/honour, -re instead of -er like centre/theatre, -ise instead of -ize like realise/organise, licence noun / license verb distinctions, travelled, catalogue).
3. Grammatical errors, verb agreement, modal auxiliary constructions (e.g. "should have" instead of "should of").
4. Punctuation and sentence flow adhering to standard British English.
${commonRules}

You MUST respond strictly with a valid JSON object matching this schema:
{
  "original": "exact original text",
  "corrected": "complete corrected text in British English",
  "issues": [
    {
      "original": "the exact word or phrase with issue",
      "replacement": "British English replacement",
      "type": "spelling" | "grammar" | "vocabulary" | "punctuation",
      "explanation": "concise explanation referencing British English rule"
    }
  ],
  "summary": "a brief 1-sentence summary of corrections"
}
Do not output markdown code blocks. Output raw JSON only.`
      };
    }
  }

  async checkHealth() {
    return new Promise((resolve) => {
      const req = http.get(`${this.baseUrl}/api/tags`, { timeout: 3000 }, (res) => {
        resolve(res.statusCode === 200);
      });
      req.on('error', () => resolve(false));
      req.on('timeout', () => {
        req.destroy();
        resolve(false);
      });
    });
  }

  async getAvailableModels() {
    return new Promise((resolve, reject) => {
      const req = http.get(`${this.baseUrl}/api/tags`, { timeout: 4000 }, (res) => {
        let raw = '';
        res.on('data', chunk => raw += chunk);
        res.on('end', () => {
          try {
            const data = JSON.parse(raw);
            const models = (data.models || []).map(m => m.name);
            resolve(models);
          } catch (e) {
            resolve([]);
          }
        });
      });
      req.on('error', () => resolve([]));
      req.on('timeout', () => {
        req.destroy();
        resolve([]);
      });
    });
  }

  async resolveBestModel() {
    const models = await this.getAvailableModels();
    if (models.includes(this.preferredModel)) {
      this.activeModel = this.preferredModel;
      return this.activeModel;
    }
    const gemmaModel = models.find(m => m.includes('gemma4') || m.includes('gemma'));
    if (gemmaModel) {
      this.activeModel = gemmaModel;
      return this.activeModel;
    }
    if (models.length > 0) {
      this.activeModel = models[0];
      return this.activeModel;
    }
    this.activeModel = this.preferredModel;
    return this.activeModel;
  }

  async checkGrammarAndSpelling(text, customModel = null, customDialect = null) {
    const modelToUse = customModel || this.activeModel || this.preferredModel;
    const dialectToUse = customDialect || this.activeDialect || 'en-GB';
    const startTime = Date.now();
    const config = this.getPromptConfig(dialectToUse);

    const payload = JSON.stringify({
      model: modelToUse,
      messages: [
        { role: 'system', content: config.systemPrompt },
        { role: 'user', content: `${config.instruction}\n\n"${text}"` }
      ],
      format: 'json',
      stream: false
    });

    return new Promise((resolve, reject) => {
      const url = new URL(`${this.baseUrl}/api/chat`);
      const req = http.request({
        hostname: url.hostname,
        port: url.port,
        path: url.pathname,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(payload)
        },
        timeout: 45000
      }, (res) => {
        let raw = '';
        res.on('data', chunk => raw += chunk);
        res.on('end', () => {
          const durationMs = Date.now() - startTime;
          try {
            const data = JSON.parse(raw);
            const content = data.message ? (data.message.content || '').trim() : '';

            if (!content) {
              resolve({
                success: true,
                original: text,
                corrected: text,
                issues: [],
                summary: `${config.dialectName} review complete.`,
                durationMs,
                model: modelToUse,
                dialect: dialectToUse
              });
              return;
            }

            // 1. Clean markdown code fences if model wrapped JSON in ```json ... ```
            let cleaned = content;
            if (cleaned.startsWith('```')) {
              cleaned = cleaned.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim();
            }

            // 2. Extract outermost JSON block
            const startIdx = cleaned.indexOf('{');
            const endIdx = cleaned.lastIndexOf('}');
            let jsonCandidate = (startIdx !== -1 && endIdx !== -1 && endIdx > startIdx)
              ? cleaned.slice(startIdx, endIdx + 1)
              : cleaned;

            function sanitizeJson(str) {
              return str
                // Fix invalid JSON escapes (e.g. Windows paths like F:\Projects -> F:\\Projects)
                .replace(/\\(?!["\\/bfnrt]|u[0-9a-fA-F]{4})/g, '\\\\')
                // Strip trailing commas before closing braces/brackets
                .replace(/,\s*([}\]])/g, '$1');
            }

            let parsed = null;

            // Attempt 1: Standard JSON parse
            try {
              parsed = JSON.parse(jsonCandidate);
            } catch (e1) {
              // Attempt 2: Sanitized JSON parse (handles invalid escapes like Windows paths)
              try {
                parsed = JSON.parse(sanitizeJson(jsonCandidate));
              } catch (e2) {
                // Attempt 3: Regex extraction fallback
                const correctedMatch = jsonCandidate.match(/"corrected"\s*:\s*"((?:[^"\\]|\\.)*)"/);
                let extractedCorrected = null;
                if (correctedMatch && correctedMatch[1]) {
                  try {
                    extractedCorrected = JSON.parse(`"${sanitizeJson(correctedMatch[1])}"`);
                  } catch (e3) {
                    extractedCorrected = correctedMatch[1]
                      .replace(/\\n/g, '\n')
                      .replace(/\\r/g, '')
                      .replace(/\\t/g, '\t')
                      .replace(/\\"/g, '"')
                      .replace(/\\\\/g, '\\');
                  }
                }

                const issues = [];
                const issueRegex = /\{\s*"original"\s*:\s*"((?:[^"\\]|\\.)*)"\s*,\s*"replacement"\s*:\s*"((?:[^"\\]|\\.)*)"(?:[^{}]*?"type"\s*:\s*"((?:[^"\\]|\\.)*)")?(?:[^{}]*?"explanation"\s*:\s*"((?:[^"\\]|\\.)*)")?\s*\}/g;
                let m;
                while ((m = issueRegex.exec(jsonCandidate)) !== null) {
                  try {
                    const orig = JSON.parse(`"${sanitizeJson(m[1])}"`);
                    const repl = JSON.parse(`"${sanitizeJson(m[2])}"`);
                    const type = m[3] ? JSON.parse(`"${sanitizeJson(m[3])}"`) : 'grammar';
                    const exp = m[4] ? JSON.parse(`"${sanitizeJson(m[4])}"`) : '';
                    if (orig && orig !== repl) {
                      issues.push({ original: orig, replacement: repl, type, explanation: exp });
                    }
                  } catch (e4) {}
                }

                parsed = {
                  original: text,
                  corrected: extractedCorrected || text,
                  issues,
                  summary: `${config.dialectName} review complete.`
                };
              }
            }

            // Validate issues list
            const rawIssues = (parsed && Array.isArray(parsed.issues)) ? parsed.issues : [];
            const validIssues = rawIssues.filter(issue => {
              if (!issue || typeof issue !== 'object') return false;
              const orig = String(issue.original || '').trim();
              const repl = String(issue.replacement !== undefined ? issue.replacement : '').trim();
              return orig.length > 0 && orig !== repl;
            });

            // Strict sanity check: ensure corrected text is clean human-readable text
            // NEVER return raw JSON, schema markers, or escaped metadata
            let resolvedCorrected = (parsed && typeof parsed.corrected === 'string' && parsed.corrected.trim())
              ? parsed.corrected.trim()
              : text;

            if (resolvedCorrected.startsWith('{"') ||
                resolvedCorrected.startsWith('`') ||
                resolvedCorrected.includes('"issues":') ||
                resolvedCorrected.includes('"replacement":') ||
                resolvedCorrected.includes('"model":')) {
              resolvedCorrected = text;
            }

            resolve({
              success: true,
              original: (parsed && parsed.original) || text,
              corrected: resolvedCorrected,
              issues: validIssues,
              summary: (parsed && parsed.summary) || `${config.dialectName} review complete.`,
              durationMs,
              model: modelToUse,
              dialect: dialectToUse
            });
          } catch (err) {
            // Safe fallback: ALWAYS return clean user text, NEVER raw JSON or HTTP envelopes
            resolve({
              success: true,
              original: text,
              corrected: text,
              issues: [],
              summary: `${config.dialectName} review complete (fallback to original).`,
              durationMs,
              model: modelToUse,
              dialect: dialectToUse,
              parseError: err.message
            });
          }
        });
      });

      req.on('error', (err) => {
        resolve({
          success: false,
          error: `Ollama connection failed: ${err.message}. Ensure Ollama is running at ${this.baseUrl}.`,
          durationMs: Date.now() - startTime
        });
      });

      req.on('timeout', () => {
        req.destroy();
        resolve({
          success: false,
          error: 'Ollama request timed out after 45s.',
          durationMs: Date.now() - startTime
        });
      });

      req.write(payload);
      req.end();
    });
  }
}

module.exports = { OllamaClient };
