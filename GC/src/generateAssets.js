const fs = require('fs');
const path = require('path');

// SVG Icon (Standard Idle: British Racing Green / Neon Cyan "GC" badge)
const svgNormal = `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="16" fill="#0d1117"/>
  <rect x="2" y="2" width="60" height="60" rx="14" fill="none" stroke="#00e5ff" stroke-width="2.5" opacity="0.8"/>
  <text x="32" y="38" font-family="Segoe UI, Arial, sans-serif" font-weight="900" font-size="24" fill="#ffffff" text-anchor="middle" letter-spacing="1">GC</text>
  <circle cx="50" cy="14" r="5" fill="#00e5ff"/>
  <text x="32" y="52" font-family="Segoe UI, Arial, sans-serif" font-weight="700" font-size="9" fill="#00e5ff" text-anchor="middle" letter-spacing="1.5">UK</text>
</svg>`;

// SVG Icon (Recording Active: Bright Pulsing Coral Red)
const svgRecording = `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="16" fill="#160808"/>
  <rect x="2" y="2" width="60" height="60" rx="14" fill="none" stroke="#ff3366" stroke-width="3"/>
  <text x="32" y="38" font-family="Segoe UI, Arial, sans-serif" font-weight="900" font-size="24" fill="#ffffff" text-anchor="middle" letter-spacing="1">GC</text>
  <circle cx="50" cy="14" r="6" fill="#ff3366"/>
  <text x="32" y="52" font-family="Segoe UI, Arial, sans-serif" font-weight="700" font-size="9" fill="#ff3366" text-anchor="middle" letter-spacing="1.5">REC</text>
</svg>`;

const assetsDir = path.join(__dirname, '..', 'assets');
if (!fs.existsSync(assetsDir)) fs.mkdirSync(assetsDir, { recursive: true });

fs.writeFileSync(path.join(assetsDir, 'icon.svg'), svgNormal);
fs.writeFileSync(path.join(assetsDir, 'icon-recording.svg'), svgRecording);

console.log('SVG icons written successfully to assets folder.');
