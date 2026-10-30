"""Points character data at the MakeHuman models built by build_fighter.py.

    python3 tools/mpfb/use_models.py kenji brutus ...

For each fighter: model_scene -> assets/characters/mh/<id>/<id>.gltf, body_albedo and
alt_body_albedo -> its skin.png and skin_alt.png, no separate hair pieces (the model carries
hair, brows and lashes), no generated outfit (the model carries its clothes). Colours, scale,
moves and everything else stay. The old resources are left on disk.
"""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def use(fighter):
    path = REPO / "data" / "characters" / f"{fighter}.tres"
    text = path.read_text()
    ids = set(re.findall(r'id="([^"]+)"', text))

    def new_id(base):
        n = 1
        while f"{base}{n}" in ids:
            n += 1
        ids.add(f"{base}{n}")
        return f"{base}{n}"

    # Drop the resources the MakeHuman model replaces.
    dropped = []
    keep_lines = []
    for line in text.splitlines():
        m = re.match(r'\[ext_resource type="[^"]+" path="([^"]+)" id="([^"]+)"\]', line)
        if m and (m.group(1).startswith("res://assets/characters/base/")
                  or m.group(1).startswith("res://assets/characters/hair/")
                  or m.group(1).startswith("res://assets/characters/outfits/")
                  or re.match(r"res://assets/characters/(mira|jin)/", m.group(1))):
            dropped.append(m.group(2))
            continue
        keep_lines.append(line)
    text = "\n".join(keep_lines) + "\n"
    for prop in ("model_scene", "body_albedo", "alt_body_albedo", "outfit_mesh", "outfit_body_mesh", "hair_scenes"):
        text = re.sub(rf"^{prop} = .*\n", "", text, flags=re.M)
    model_id, skin_id, alt_id = new_id("mh_model_"), new_id("mh_skin_"), new_id("mh_skin_alt_")
    base = f"res://assets/characters/mh/{fighter}"
    new_res = (f'[ext_resource type="PackedScene" path="{base}/{fighter}.gltf" id="{model_id}"]\n'
               f'[ext_resource type="Texture2D" path="{base}/textures/skin.png" id="{skin_id}"]\n'
               f'[ext_resource type="Texture2D" path="{base}/textures/skin_alt.png" id="{alt_id}"]\n')
    first = text.index("[ext_resource")
    text = text[:first] + new_res + text[first:]
    props = (f'model_scene = ExtResource("{model_id}")\n'
             f'hair_scenes = Array[PackedScene]([])\n'
             f'body_albedo = ExtResource("{skin_id}")\n'
             f'alt_body_albedo = ExtResource("{alt_id}")\n')
    text = re.sub(r"^(portrait = .*\n)", lambda m: m.group(1) + props, text, count=1, flags=re.M)
    # load_steps (if any) is a hint Godot recomputes; drop it rather than keep a wrong count.
    text = re.sub(r" load_steps=\d+", "", text, count=1)
    leftover = [i for i in dropped if f'ExtResource("{i}")' in text]
    if leftover:
        raise SystemExit(f"{fighter}: still uses dropped resources {leftover}")
    path.write_text(text)
    print(fighter, "->", f"{base}/{fighter}.gltf", "dropped", len(dropped), "resources")


for f in sys.argv[1:]:
    use(f)
