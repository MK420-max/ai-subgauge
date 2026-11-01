# Third-party notices

The Windows application ships the following third-party artwork as source assets and embeds the PNG masks in AISubGauge2.exe. Runtime-tinted and downsampled versions retain the same licenses.

| Shipped file | Source | License |
| --- | --- | --- |
| assets/logos/openai.svg | Simple Icons 15.22.0 | CC0 1.0 Universal |
| assets/logos/openai-512.png | Rendered from openai.svg | CC0 1.0 Universal |
| assets/logos/claude.svg | Simple Icons 16.35.0 | CC0 1.0 Universal |
| assets/logos/claude-512.png | Rendered from claude.svg | CC0 1.0 Universal |
| assets/logos/grok.svg | Lobe Icons, @lobehub/icons-static-svg 1.97.0 | MIT, copyright (c) 2023 LobeHub |
| assets/logos/grok-512.png | Rendered from grok.svg | MIT, copyright (c) 2023 LobeHub |
| assets/logos/LICENSE-LobeHub.txt | Lobe Icons license text | MIT notice reproduced below |
| assets/logos/SOURCES.md | Reviewed upstream source and hash manifest | Project MIT; asset licenses as above |

The copied SOURCES.md also documents other upstream assets that are not shipped by this Windows project. The table above is the Windows artwork inventory. The AI SubGauge application artwork in assets/brand/ and the app.ico assembled from it are covered by the project's root MIT LICENSE.

## Simple Icons: CC0 1.0 Universal

Simple Icons dedicates its icons to the public domain under CC0 1.0 Universal. To the extent permitted by law, copyright and related rights are waived; the CC0 fallback license applies where a waiver is not effective. The icons are provided without warranty. CC0 does not grant trademark or patent rights.

License: https://creativecommons.org/publicdomain/zero/1.0/
Legal code: https://creativecommons.org/publicdomain/zero/1.0/legalcode
Source: https://github.com/simple-icons/simple-icons

## Lobe Icons: MIT

Source: https://github.com/lobehub/lobe-icons
Package: @lobehub/icons-static-svg@1.97.0

MIT License

Copyright (c) 2023 LobeHub

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Runtime distribution

The self-contained AISubGauge2.exe also bundles Microsoft .NET and Windows Desktop runtime components under their upstream licenses. The exact runtime packs' license texts and accompanying third-party notices are preserved in DOTNET-NOTICES.txt in each binary distribution and installation. The build reads the selected runtime versions from restore metadata and does not substitute this project's MIT license for those terms.

## Trademarks

OpenAI, Claude, Anthropic, Grok, xAI, and other product names and logos are trademarks of their respective owners. Their use identifies supported services and does not imply affiliation, sponsorship, or endorsement. The artwork licenses do not grant trademark rights.
