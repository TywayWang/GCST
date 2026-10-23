const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

function createPng(width, height, getPixel) {
  // getPixel(x, y) -> [r, g, b, a]
  const rawBytes = [];
  for (let y = 0; y < height; y++) {
    rawBytes.push(0); // filter type: 0 (None)
    for (let x = 0; x < width; x++) {
      const [r, g, b, a] = getPixel(x, y);
      rawBytes.push(r, g, b, a);
    }
  }

  const compressedData = zlib.deflateSync(Buffer.from(rawBytes));

  function crc32(buf) {
    let crc = -1;
    for (let i = 0; i < buf.length; i++) {
      let byte = buf[i];
      for (let j = 0; j < 8; j++) {
        if ((crc ^ byte) & 1) {
          crc = (crc >>> 1) ^ 0xedb88320;
        } else {
          crc = crc >>> 1;
        }
        byte = byte >>> 1;
      }
    }
    return (crc ^ -1) >>> 0;
  }

  function makeChunk(type, data) {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length, 0);

    const typeBuf = Buffer.from(type, 'ascii');
    const typeAndData = Buffer.concat([typeBuf, data]);

    const crcBuf = Buffer.alloc(4);
    crcBuf.writeUInt32BE(crc32(typeAndData), 0);

    return Buffer.concat([len, typeAndData, crcBuf]);
  }

  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

  const ihdrData = Buffer.alloc(13);
  ihdrData.writeUInt32BE(width, 0);
  ihdrData.writeUInt32BE(height, 4);
  ihdrData[8] = 8; // bit depth
  ihdrData[9] = 6; // color type: RGBA
  ihdrData[10] = 0; // compression
  ihdrData[11] = 0; // filter
  ihdrData[12] = 0; // interlace

  const ihdrChunk = makeChunk('IHDR', ihdrData);
  const idatChunk = makeChunk('IDAT', compressedData);
  const iendChunk = makeChunk('IEND', Buffer.alloc(0));

  return Buffer.concat([signature, ihdrChunk, idatChunk, iendChunk]);
}

// Generate Normal Icon (Dark blue/cyan rounded badge with "GC" and cyan dot)
const normalPng = createPng(32, 32, (x, y) => {
  // rounded rect check
  const inBorder = (x >= 2 && x <= 29 && y >= 2 && y <= 29);
  const corner = (x < 6 && y < 6) || (x > 25 && y < 6) || (x < 6 && y > 25) || (x > 25 && y > 25);
  if (!inBorder || corner) return [0, 0, 0, 0];

  const onEdge = (x === 2 || x === 29 || y === 2 || y === 29 ||
                 (x === 3 && y === 5) || (x === 5 && y === 3) ||
                 (x === 28 && y === 5) || (x === 26 && y === 3));
  if (onEdge) return [0, 229, 255, 255]; // Cyan border

  // Dot at top-right
  const dx = x - 24;
  const dy = y - 7;
  if (dx * dx + dy * dy <= 6) return [0, 229, 255, 255]; // Cyan dot

  // Draw G
  const isG = (x >= 7 && x <= 14 && (y === 10 || y === 22)) ||
              (x === 7 && y >= 10 && y <= 22) ||
              (x === 14 && y >= 16 && y <= 22) ||
              (y === 16 && x >= 11 && x <= 14);

  // Draw C
  const isC = (x >= 17 && x <= 24 && (y === 10 || y === 22)) ||
              (x === 17 && y >= 10 && y <= 22);

  if (isG || isC) return [255, 255, 255, 255];

  return [13, 17, 23, 250]; // Deep dark background
});

// Generate Recording Icon (Red pulsing badge)
const recordingPng = createPng(32, 32, (x, y) => {
  const inBorder = (x >= 2 && x <= 29 && y >= 2 && y <= 29);
  const corner = (x < 6 && y < 6) || (x > 25 && y < 6) || (x < 6 && y > 25) || (x > 25 && y > 25);
  if (!inBorder || corner) return [0, 0, 0, 0];

  const onEdge = (x === 2 || x === 29 || y === 2 || y === 29);
  if (onEdge) return [255, 51, 102, 255]; // Hot red border

  // Bright red recording circle at top right
  const dx = x - 24;
  const dy = y - 7;
  if (dx * dx + dy * dy <= 8) return [255, 51, 102, 255];

  // Draw G
  const isG = (x >= 7 && x <= 14 && (y === 10 || y === 22)) ||
              (x === 7 && y >= 10 && y <= 22) ||
              (x === 14 && y >= 16 && y <= 22) ||
              (y === 16 && x >= 11 && x <= 14);

  // Draw C
  const isC = (x >= 17 && x <= 24 && (y === 10 || y === 22)) ||
              (x === 17 && y >= 10 && y <= 22);

  if (isG || isC) return [255, 255, 255, 255];

  return [28, 8, 14, 250]; // Deep red-black background
});

const assetsDir = path.join(__dirname, '..', 'assets');
fs.writeFileSync(path.join(assetsDir, 'icon.png'), normalPng);
fs.writeFileSync(path.join(assetsDir, 'icon-recording.png'), recordingPng);
console.log('Crisp 32x32 RGBA PNG icons generated successfully.');
