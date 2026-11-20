"""Regenerate the browser's raster artwork from Bark's macOS icon (Pillow)."""
import base64
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def main():
    output = Path(__file__).resolve().parent
    icon = Image.open(output.parents[2] / 'apps/macos/resources/icon.png').convert('RGBA')
    for size in (16, 24, 32, 48, 64, 128, 256):
        icon.resize((size, size), Image.Resampling.LANCZOS).save(output / f'bark-{size}.png', optimize=True)

    # Chromium uses an image of the product name on its Version and payment surfaces.
    for size in (22, 32, 44, 64):
        height = size * 4
        font = ImageFont.truetype('/System/Library/Fonts/HelveticaNeue.ttc', round(height * 0.80))
        left, top, right, bottom = font.getbbox('Bark')
        text_x = height + round(height * 0.10)
        width = text_x + right - left
        for suffix, color in [('', '#34363b'), ('_white', '#ffffff')]:
            image = Image.new('RGBA', (width, height))
            image.alpha_composite(icon.resize((height, height), Image.Resampling.LANCZOS))
            ImageDraw.Draw(image).text((text_x - left, (height - bottom - top) / 2),
                                       'Bark', font=font, fill=color)
            image.resize((round(width / 4), size), Image.Resampling.LANCZOS).save(
                output / f'bark-name-{size}{suffix}.png', optimize=True)

    # The first-run page reserves a 160-unit canvas for an 80-unit logo.
    png = base64.b64encode((output / 'bark-256.png').read_bytes()).decode('ascii')
    (output / 'bark-intro.svg').write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 160">\n'
        '  <style>\n'
        '    @media (prefers-reduced-motion: no-preference) {\n'
        '      image { transform-origin: 80px 80px; animation: appear .45s ease-out; }\n'
        '      @keyframes appear { from { opacity: 0; transform: scale(.9); } }\n'
        '    }\n'
        '  </style>\n'
        f'  <image x="30" y="30" width="100" height="100" href="data:image/png;base64,{png}"/>\n'
        '</svg>\n')


if __name__ == '__main__':
    main()
