"""Review aid: an animated GIF and a frame strip per tier of a lone block with its machinery loop,
from the raw renders (tools/render/out/raw). Usage: python tools/render/preview_gif.py [out_dir]"""
import os
import sys
from PIL import Image
raw = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out', 'raw')
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out')
for tier in ['basic', 'fast', 'express', 'turbo']:
    base = Image.open(os.path.join(raw, r'block-%s-000-0.png' % tier)).convert('RGBA')
    sh = Image.open(os.path.join(raw, r'block-shadow-0.png')).convert('RGBA')
    frames = []
    for f in range(16):
        bg = Image.new('RGBA', base.size, (74, 72, 68, 255))
        a = sh.getchannel('A').point(lambda v: int(v * 0.6))
        dark = Image.new('RGBA', base.size, (0, 0, 0, 255)); dark.putalpha(a)
        bg.alpha_composite(dark); bg.alpha_composite(base)
        bg.alpha_composite(Image.open(os.path.join(raw, r'anim-%s-0-%02d.png' % (tier, f))).convert('RGBA'))
        frames.append(bg.crop((48, 0, 336, 330)).resize((216, 248), Image.LANCZOS).convert('P', palette=Image.ADAPTIVE))
    frames[0].save(os.path.join(out, r'anim-%s.gif' % tier), save_all=True, append_images=frames[1:], duration=67, loop=0)
    strip = Image.new('RGBA', (216 * 8, 248))
    for i in range(8):
        strip.paste(frames[i * 2].convert('RGBA'), (i * 216, 0))
    strip.save(os.path.join(out, r'anim-strip-%s.png' % tier))
print('ok')
