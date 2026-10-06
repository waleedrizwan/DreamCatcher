# App icon

`gen.py` draws the Dream Catcher icon (night sky, gold hoop, woven web,
crescent moon, three feathers) as SVG inside an HTML page; headless Chrome
renders it to the 1024 px PNG the asset catalog uses.

```sh
python3 tools/icon/gen.py /tmp/icon.html
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
  --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1024,1024 --screenshot=/tmp/icon.png file:///tmp/icon.html
sips -g hasAlpha /tmp/icon.png   # must be "no" — App Store rejects alpha
cp /tmp/icon.png ios/DreamCatcher/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
```
