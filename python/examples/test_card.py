"""Draw a colour test card and upload it.

    python python/examples/test_card.py --slot 1            # upload
    python python/examples/test_card.py --save card.png     # just save the image
"""
import argparse
import asyncio

from PIL import Image, ImageDraw

from ulani_epaper import image as im
from ulani_epaper.client import connect
from ulani_epaper.protocol import HEIGHT, WIDTH


def test_card() -> Image.Image:
    img = Image.new("RGB", (WIDTH, HEIGHT), "white")
    d = ImageDraw.Draw(img)
    band = WIDTH // len(im.PALETTE)
    for c in im.PALETTE:  # one band per native colour
        d.rectangle((c.index * band, 0, (c.index + 1) * band - 1, 150), fill=c.rgb)
    for x in range(WIDTH):  # blue -> green -> red gradient to show dithering
        t = x / (WIDTH - 1)
        d.line((x, 160, x, 300), fill=(int(255 * t), int(255 * (1 - abs(2 * t - 1))), int(255 * (1 - t))))
    d.text((WIDTH // 2, 390), "ulani-epaper", font=im.load_font(64), fill="black", anchor="mm")
    d.text((WIDTH // 2, 445), "PC 透過 BLE 完全控制", font=im.load_font(36), fill="red", anchor="mm")
    return img


async def upload(slot: int) -> None:
    async with connect() as cal:
        # Classic keeps the native colour bands pure; Natural would mix other inks into them
        print(await cal.upload(im.encode(test_card(), colours="classic"), slot))
    print(f"wait ~40 s for the refresh, then `ulani show {slot}` if another page is on screen")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--slot", type=int, choices=range(1, 5))
    ap.add_argument("--save")
    args = ap.parse_args()
    if args.slot is None and not args.save:
        ap.error("give --slot N and/or --save FILE")
    if args.save:
        test_card().save(args.save)
    if args.slot:
        asyncio.run(upload(args.slot))
