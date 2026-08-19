const sharp = require('sharp');
const pngToIco = require('png-to-ico').default;
const fs = require('fs');
const path = require('path');

const SRC = path.join(__dirname, 'nah-logo-N.svg');
const OUT = path.join(__dirname, 'icons');
fs.mkdirSync(OUT, { recursive: true });

// The N mark is viewBox 0 0 63 60. Render it centered on a square transparent
// canvas with ~12% padding so it reads well as an app icon at small sizes.
const svg = fs.readFileSync(SRC, 'utf8');

async function renderSquare(size) {
  const pad = Math.round(size * 0.12);
  const inner = size - pad * 2;
  // Render the logo to `inner` height, then composite centered on a square.
  const logo = await sharp(Buffer.from(svg), { density: 384 })
    .resize({ height: inner, fit: 'inside' })
    .png()
    .toBuffer();
  const meta = await sharp(logo).metadata();
  return sharp({
    create: { width: size, height: size, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  })
    .composite([{ input: logo, left: Math.round((size - meta.width) / 2), top: Math.round((size - meta.height) / 2) }])
    .png()
    .toBuffer();
}

async function main() {
  const sizes = [16, 24, 32, 48, 64, 128, 256];
  const pngs = {};
  for (const s of sizes) {
    pngs[s] = await renderSquare(s);
    fs.writeFileSync(path.join(OUT, `icon-${s}.png`), pngs[s]);
  }
  // res/icon.png is the general-purpose 256 logo.
  fs.writeFileSync(path.join(OUT, 'icon.png'), pngs[256]);

  // Multi-resolution ICOs.
  const appIco = await pngToIco(sizes.map((s) => path.join(OUT, `icon-${s}.png`)));
  fs.writeFileSync(path.join(OUT, 'app_icon.ico'), appIco);
  fs.writeFileSync(path.join(OUT, 'icon.ico'), appIco);

  // Tray icon: smaller set is enough.
  const trayIco = await pngToIco([16, 24, 32, 48].map((s) => path.join(OUT, `icon-${s}.png`)));
  fs.writeFileSync(path.join(OUT, 'tray-icon.ico'), trayIco);

  console.log('Generated:', fs.readdirSync(OUT).join(', '));
}
main().catch((e) => { console.error(e); process.exit(1); });
