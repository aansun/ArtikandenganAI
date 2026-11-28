# NNAI Translator 1.2.0

Send books to an Xteink e-ink reader, a clearer book page, and Settings sorted into tabs.

## New: send to an Xteink reader

- Send a finished book over Wi-Fi from its page to an Xteink X4 or X3 running the
  [CrossPoint](https://github.com/crosspoint-reader/crosspoint-reader) firmware. Xteink's own firmware is not
  supported.
- On the reader, open **File Transfer** and keep the Mac on the same network. The app looks for
  `crosspoint.local`; type the reader's IP address under **Settings > Xteink** if that is not found. The
  folder (`/Books` unless you choose another) is made when it is missing.
- A copy is prepared for the screen first: pictures become grayscale JPEG no larger than the screen and
  embedded fonts are left out. The text and your file are not changed. Switch this off to send the file as it
  is. The picture settings follow [EPUB Kit](https://github.com/b1rdmania/epubkit).
- After an upload the file's size on the reader is checked. A file of the same name that the app did not send
  is replaced only after you agree.
- Only addresses on your own network are accepted. macOS may ask to allow **Local Network** access.
- Sending was tested with a stand-in reader, not yet with a real device.

## Changed

- The book page has the actions on the left, grouped (read and send, metadata, final check, manage), and the
  book with its metadata on the right. The final check, **Translate again** and **Delete** are folded until
  you open them. Apple Books, Finder and Kindle show the icons of the apps installed on your Mac.
- **Settings** has a tab for each kind: General, Engines, Translation, Library, Kindle, Xteink and About.

## Install

Download `NNAI-Translator-1.2.0.dmg`, open it and drag the app to Applications (replace the old copy). Quit the
old app first so it can stop its engine cleanly; the queue resumes when you open the new one, unless you had
paused it. Your settings, library and the Python libraries installed on first launch are kept.
`NNAI-Translator-1.2.0.zip` holds the same app and is what the in-app updater downloads.

## Please buy the books

This tool only helps you read a book you legitimately own in a language you understand. Buy the official
edition, and the official translation when there is one. Do not share or sell the translations it makes.
