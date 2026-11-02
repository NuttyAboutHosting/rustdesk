# NAH brand assets for the client

Regenerate the app icons from the source logo (needs Node):

```bash
cd nah-assets
npm install sharp png-to-ico
node gen-icons.js
# then copy icons/* over the RustDesk defaults:
cp icons/app_icon.ico ../flutter/windows/runner/resources/app_icon.ico
cp icons/icon.ico ../res/icon.ico
cp icons/icon.png ../res/icon.png
cp icons/tray-icon.ico ../res/tray-icon.ico
```

`nah-logo-N.svg` is the NAH "n" logomark (from the NAH_BRANDING skill).
`../flutter/assets/icon.svg` (the in-app logo) is this same file.
