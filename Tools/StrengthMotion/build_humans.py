"""Build NOOP's redistributable male and female exercise-guide characters.

Run from Blender with MPFB 2.0.17 enabled:

    blender -b --python build_humans.py -- /path/to/output

MPFB's bundled meshes, targets, and rig data are CC0. This script applies a
fixed phenotype, creates fitted athletic clothing, and exports a compact GLB
with a Mixamo-compatible skeleton for the shared iOS/Android viewer.
"""

from __future__ import annotations

import math
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import bmesh
import bpy
from mathutils import Vector


@dataclass(frozen=True)
class CharacterStyle:
    key: str
    gender: float
    muscle: float
    weight: float
    height: float
    proportions: float
    race: tuple[float, float, float]
    skin: tuple[float, float, float, float]
    top: tuple[float, float, float, float]
    bottoms: tuple[float, float, float, float]
    hair: tuple[float, float, float, float]
    top_region: Callable[[Vector], bool]
    bottoms_region: Callable[[Vector], bool]
    skin_asset: str
    outfit_asset: str
    hair_asset: str


MAN = CharacterStyle(
    key="man",
    gender=0.92,
    muscle=0.70,
    weight=0.43,
    height=0.56,
    proportions=0.56,
    race=(0.18, 0.12, 0.70),
    skin=(0.48, 0.24, 0.15, 1.0),
    top=(0.035, 0.12, 0.30, 1.0),
    bottoms=(0.035, 0.043, 0.055, 1.0),
    hair=(0.035, 0.018, 0.012, 1.0),
    top_region=lambda center: (
        1.01 <= center.z <= 1.43
        and abs(center.x) <= 0.31
        and center.y <= 0.16
    ),
    bottoms_region=lambda center: (
        0.72 <= center.z <= 1.03
        and abs(center.x) <= 0.31
        and center.y <= 0.18
    ),
    skin_asset="young_caucasian_male.mhmat",
    outfit_asset="male_casualsuit04.mhclo",
    hair_asset="short03.mhclo",
)

WOMAN = CharacterStyle(
    key="woman",
    gender=0.08,
    muscle=0.56,
    weight=0.40,
    height=0.51,
    proportions=0.52,
    race=(0.12, 0.28, 0.60),
    skin=(0.57, 0.31, 0.21, 1.0),
    top=(0.42, 0.018, 0.035, 1.0),
    bottoms=(0.042, 0.048, 0.061, 1.0),
    hair=(0.055, 0.026, 0.016, 1.0),
    top_region=lambda center: (
        0.96 <= center.z <= 1.38
        and abs(center.x) <= 0.255
        and center.y <= 0.17
    ),
    bottoms_region=lambda center: (
        (
            (0.15 <= center.z < 0.88 and abs(center.x) <= 0.18)
            or (0.88 <= center.z <= 1.04 and abs(center.x) <= 0.31)
        )
        and center.y <= 0.18
    ),
    skin_asset="young_asian_female.mhmat",
    outfit_asset="female_casualsuit01.mhclo",
    hair_asset="ponytail01.mhclo",
)


def mpfb_service(module_suffix: str, name: str):
    for module_name, module in sys.modules.items():
        if module_name.endswith(f".mpfb.services.{module_suffix}"):
            return getattr(module, name)
    raise RuntimeError(
        "MPFB is not enabled. Install MPFB 2.0.17 as a Blender extension "
        "before running this generator."
    )


def clear_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (
        bpy.data.meshes,
        bpy.data.armatures,
        bpy.data.materials,
        bpy.data.images,
        bpy.data.cameras,
        bpy.data.lights,
    ):
        for datablock in list(datablocks):
            if datablock.users == 0:
                datablocks.remove(datablock)


def material(
    name: str,
    color: tuple[float, float, float, float],
    *,
    roughness: float,
    metallic: float = 0.0,
) -> bpy.types.Material:
    result = bpy.data.materials.new(name)
    result.diffuse_color = color
    result.use_nodes = True
    shader = result.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = color
    shader.inputs["Roughness"].default_value = roughness
    shader.inputs["Metallic"].default_value = metallic
    shader.inputs["Specular IOR Level"].default_value = 0.34
    return result


def assign_material(obj: bpy.types.Object, value: bpy.types.Material) -> None:
    obj.data.materials.clear()
    obj.data.materials.append(value)
    for polygon in obj.data.polygons:
        polygon.material_index = 0


def apply_athletic_materials(
    outfit: bpy.types.Object,
    shoes: bpy.types.Object,
    style: CharacterStyle,
) -> None:
    top = material(
        f"NoopTrainer{style.key.title()}Top",
        style.top,
        roughness=0.78,
    )
    bottoms = material(
        f"NoopTrainer{style.key.title()}Bottoms",
        style.bottoms,
        roughness=0.82,
    )
    outfit.data.materials.clear()
    outfit.data.materials.append(top)
    outfit.data.materials.append(bottoms)
    for polygon in outfit.data.polygons:
        polygon.material_index = 0 if polygon.center.z >= 1.02 else 1

    sneaker = shoes.data.materials[0]
    shoes.data.materials.clear()
    shoes.data.materials.append(sneaker)
    shoes.data.materials.append(bottoms)
    for polygon in shoes.data.polygons:
        polygon.material_index = 1 if polygon.center.z >= 0.13 else 0


def paint_body(
    body: bpy.types.Object,
    style: CharacterStyle,
    skin: bpy.types.Material,
    top: bpy.types.Material,
    bottoms: bpy.types.Material,
    shoes: bpy.types.Material,
) -> None:
    body.data.materials.clear()
    for value in (skin, top, bottoms, shoes):
        body.data.materials.append(value)
    for polygon in body.data.polygons:
        center = polygon.center
        if center.z <= 0.18:
            polygon.material_index = 3
        elif style.bottoms_region(center):
            polygon.material_index = 2
        elif style.top_region(center):
            polygon.material_index = 1
        else:
            polygon.material_index = 0


def apply_current_shape(obj: bpy.types.Object) -> None:
    if obj.data.shape_keys is None:
        return
    activate(obj)
    bpy.ops.object.shape_key_remove(all=True, apply_mix=True)


def apply_modifier(obj: bpy.types.Object, name: str) -> None:
    if name not in obj.modifiers:
        return
    activate(obj)
    while obj.modifiers.find(name) > 0:
        bpy.ops.object.modifier_move_up(modifier=name)
    bpy.ops.object.modifier_apply(modifier=name)


def activate(obj: bpy.types.Object) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    obj.hide_set(False)
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def make_garment(
    body: bpy.types.Object,
    name: str,
    keep_face: Callable[[Vector], bool],
    garment_material: bpy.types.Material,
    *,
    thickness: float = 0.007,
) -> bpy.types.Object:
    garment = body.copy()
    garment.data = body.data.copy()
    garment.name = name
    garment.data.name = f"{name}Mesh"
    bpy.context.scene.collection.objects.link(garment)

    mesh = bmesh.new()
    mesh.from_mesh(garment.data)
    remove = [
        face
        for face in mesh.faces
        if not keep_face(
            sum((vertex.co for vertex in face.verts), Vector()) / len(face.verts)
        )
    ]
    bmesh.ops.delete(mesh, geom=remove, context="FACES")
    loose = [vertex for vertex in mesh.verts if not vertex.link_faces]
    if loose:
        bmesh.ops.delete(mesh, geom=loose, context="VERTS")
    mesh.to_mesh(garment.data)
    mesh.free()
    garment.data.update()

    assign_material(garment, garment_material)
    solidify = garment.modifiers.new("Garment thickness", "SOLIDIFY")
    solidify.thickness = thickness
    solidify.offset = 1.0
    solidify.use_rim = True
    while garment.modifiers.find(solidify.name) > 0:
        bpy.context.view_layer.objects.active = garment
        bpy.ops.object.modifier_move_up(modifier=solidify.name)
    apply_modifier(garment, solidify.name)
    return garment


def add_weighted_sphere(
    rig: bpy.types.Object,
    name: str,
    location: tuple[float, float, float],
    scale: tuple[float, float, float],
    value: bpy.types.Material,
    bone_name: str,
    *,
    segments: int = 20,
    rings: int = 12,
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_uv_sphere_add(
        segments=segments,
        ring_count=rings,
        location=location,
    )
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=True, rotation=False, scale=True)
    assign_material(obj, value)
    bind_to_bone(obj, rig, bone_name)
    return obj


def bind_to_bone(
    obj: bpy.types.Object,
    rig: bpy.types.Object,
    bone_name: str,
) -> None:
    group = obj.vertex_groups.new(name=bone_name)
    group.add(range(len(obj.data.vertices)), 1.0, "REPLACE")
    modifier = obj.modifiers.new("Armature", "ARMATURE")
    modifier.object = rig
    obj.parent = rig


def bone_segment(
    rig: bpy.types.Object,
    bone_name: str,
) -> tuple[Vector, Vector]:
    bone = rig.data.bones[bone_name]
    return (
        rig.matrix_world @ bone.head_local,
        rig.matrix_world @ bone.tail_local,
    )


def make_hair(
    rig: bpy.types.Object,
    style: CharacterStyle,
    hair_material: bpy.types.Material,
) -> list[bpy.types.Object]:
    head_bone = "mixamorig:Head"
    head_base, head_top = bone_segment(rig, head_bone)
    length = (head_top - head_base).length
    center = Vector(
        (
            head_base.x,
            head_base.y + length * 0.04,
            head_base.z + length * 0.66,
        )
    )
    bpy.ops.mesh.primitive_uv_sphere_add(
        segments=28,
        ring_count=16,
        location=center,
        scale=(length * 0.56, length * 0.51, length * 0.66),
    )
    cap = bpy.context.object
    cap.name = f"NoopTrainer{style.key.title()}Hair"
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)

    mesh = bmesh.new()
    mesh.from_mesh(cap.data)
    remove = []
    for vertex in mesh.verts:
        local = vertex.co
        if local.z < -0.025 and local.y < 0.047:
            remove.append(vertex)
    bmesh.ops.delete(mesh, geom=remove, context="VERTS")
    mesh.to_mesh(cap.data)
    mesh.free()
    cap.data.update()
    activate(cap)
    bpy.ops.object.transform_apply(location=True, rotation=False, scale=False)
    assign_material(cap, hair_material)
    bind_to_bone(cap, rig, head_bone)
    result = [cap]

    if style.key == "woman":
        ponytail = add_weighted_sphere(
            rig,
            "NoopTrainerWomanPonytail",
            (
                head_base.x,
                head_base.y + length * 0.53,
                head_base.z + length * 0.36,
            ),
            (length * 0.28, length * 0.28, length * 0.58),
            hair_material,
            head_bone,
            segments=20,
            rings=12,
        )
        ponytail.rotation_euler.x = math.radians(-12)
        result.append(ponytail)
    return result


def add_face(
    rig: bpy.types.Object,
    style: CharacterStyle,
    white: bpy.types.Material,
    iris: bpy.types.Material,
    hair_material: bpy.types.Material,
) -> list[bpy.types.Object]:
    result = []
    head_base, head_top = bone_segment(rig, "mixamorig:Head")
    length = (head_top - head_base).length
    eye_z = head_base.z + length * 0.57
    eye_y = head_base.y - length * 0.37
    for side, x_direction in (("Left", 1.0), ("Right", -1.0)):
        x = head_base.x + x_direction * length * 0.17
        eye = add_weighted_sphere(
            rig,
            f"NoopTrainer{style.key.title()}{side}Eye",
            (x, eye_y, eye_z),
            (length * 0.085, length * 0.055, length * 0.072),
            white,
            "mixamorig:Head",
            segments=20,
            rings=12,
        )
        pupil = add_weighted_sphere(
            rig,
            f"NoopTrainer{style.key.title()}{side}Iris",
            (x, eye_y - length * 0.053, eye_z),
            (length * 0.034, length * 0.019, length * 0.034),
            iris,
            "mixamorig:Head",
            segments=16,
            rings=8,
        )
        result.extend((eye, pupil))
    result.extend(make_hair(rig, style, hair_material))
    return result


def create_character(style: CharacterStyle) -> tuple[bpy.types.Object, list[bpy.types.Object]]:
    HumanService = mpfb_service("humanservice", "HumanService")
    AssetService = mpfb_service("assetservice", "AssetService")
    macro = {
        "race": {
            "african": style.race[0],
            "asian": style.race[1],
            "caucasian": style.race[2],
        },
        "gender": style.gender,
        "age": 0.46,
        "muscle": style.muscle,
        "weight": style.weight,
        "height": style.height,
        "proportions": style.proportions,
        "cupsize": 0.42 if style.key == "woman" else 0.0,
        "firmness": 0.62,
    }
    body = HumanService.create_human(
        mask_helpers=True,
        detailed_helpers=True,
        extra_vertex_groups=True,
        feet_on_ground=True,
        scale=0.1,
        macro_detail_dict=macro,
    )
    body.name = f"NoopTrainer{style.key.title()}Body"
    rig = HumanService.add_builtin_rig(body, "mixamo")
    rig.name = f"NoopTrainer{style.key.title()}Rig"

    def asset_path(subdir: str, filename: str) -> str:
        path = AssetService.find_asset_absolute_path(
            filename,
            asset_subdir=subdir,
        )
        if path is None:
            raise RuntimeError(
                f"Missing CC0 MakeHuman system asset {subdir}/{filename}. "
                "Install makehuman_system_assets_cc0 before building."
            )
        return path

    HumanService.set_character_skin(
        asset_path("skins", style.skin_asset),
        body,
        skin_type="GAMEENGINE",
    )

    asset_specs = [
        ("clothes", style.outfit_asset, "Clothes"),
        ("clothes", "shoes05.mhclo", "Clothes"),
        ("hair", style.hair_asset, "Hair"),
        ("eyes", "high-poly.mhclo", "Eyes"),
        ("eyebrows", "eyebrow001.mhclo", "Eyebrows"),
        ("eyelashes", "eyelashes01.mhclo", "Eyelashes"),
    ]
    assets: list[bpy.types.Object] = []
    for index, (subdir, filename, asset_type) in enumerate(asset_specs):
        asset = HumanService.add_mhclo_asset(
            asset_path(subdir, filename),
            body,
            asset_type=asset_type,
            subdiv_levels=0,
            material_type="GAMEENGINE",
            set_up_rigging=True,
            interpolate_weights=True,
            import_subrig=True,
            import_weights=True,
        )
        asset.name = (
            f"NoopTrainer{style.key.title()}{asset_type}{index + 1}"
        )
        assets.append(asset)

    apply_athletic_materials(assets[0], assets[1], style)
    apply_current_shape(body)
    for modifier in list(body.modifiers):
        if modifier.type == "MASK":
            apply_modifier(body, modifier.name)

    for image in bpy.data.images:
        width, height = image.size
        if width > 1024 or height > 1024:
            ratio = min(1024 / width, 1024 / height)
            image.scale(
                max(1, round(width * ratio)),
                max(1, round(height * ratio)),
            )

    objects = [body, *assets]

    for obj in objects:
        if obj.type == "MESH":
            for polygon in obj.data.polygons:
                polygon.use_smooth = True
    return rig, objects


def export_glb(
    output: Path,
    rig: bpy.types.Object,
    objects: list[bpy.types.Object],
) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    rig.select_set(True)
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.export_scene.gltf(
        filepath=str(output),
        export_format="GLB",
        use_selection=True,
        export_animations=False,
        export_cameras=False,
        export_lights=False,
        export_yup=True,
        export_skins=True,
        export_all_influences=False,
        export_morph=False,
        export_materials="EXPORT",
        export_image_format="AUTO",
        export_texcoords=True,
        export_normals=True,
        export_tangents=False,
        export_attributes=False,
    )


def point_camera(
    camera: bpy.types.Object,
    target: tuple[float, float, float],
) -> None:
    camera.rotation_euler = (
        Vector(target) - camera.location
    ).to_track_quat("-Z", "Y").to_euler()


def render_preview(
    output: Path,
    rig: bpy.types.Object,
    objects: list[bpy.types.Object],
) -> None:
    bpy.ops.object.camera_add(location=(2.35, -4.0, 1.42))
    camera = bpy.context.object
    camera.data.lens = 58
    point_camera(camera, (0.0, 0.0, 0.9))
    bpy.context.scene.camera = camera

    bpy.ops.object.light_add(type="AREA", location=(-2.2, -2.8, 3.5))
    key = bpy.context.object
    key.data.energy = 1050
    key.data.shape = "DISK"
    key.data.size = 3.2
    point_camera(key, (0.0, 0.0, 1.0))

    bpy.ops.object.light_add(type="AREA", location=(2.4, -0.2, 2.4))
    rim = bpy.context.object
    rim.data.energy = 780
    rim.data.color = (1.0, 0.18, 0.12)
    rim.data.size = 2.2
    point_camera(rim, (0.0, 0.0, 1.05))

    bpy.ops.mesh.primitive_plane_add(size=8, location=(0.0, 0.0, -0.005))
    floor = bpy.context.object
    floor_material = material(
        "NOOP Preview Floor",
        (0.018, 0.021, 0.028, 1.0),
        roughness=0.84,
    )
    assign_material(floor, floor_material)

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 560
    scene.render.resolution_y = 760
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.render.filepath = str(output)
    scene.render.image_settings.color_mode = "RGBA"
    scene.world.color = (0.006, 0.007, 0.01)
    scene.view_settings.look = "AgX - Medium High Contrast"
    for obj in objects:
        obj.hide_render = False
    rig.hide_render = True
    bpy.ops.render.render(write_still=True)


def main() -> None:
    arguments = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    output_dir = Path(arguments[0] if arguments else Path(__file__).parent)
    output_dir.mkdir(parents=True, exist_ok=True)
    for style in (MAN, WOMAN):
        clear_scene()
        rig, objects = create_character(style)
        output = output_dir / f"trainer-{style.key}.glb"
        export_glb(output, rig, objects)
        render_preview(
            output_dir / f"trainer-{style.key}-preview.png",
            rig,
            objects,
        )
        print(
            "NOOP_CHARACTER_EXPORTED",
            style.key,
            output,
            output.stat().st_size,
        )


if __name__ == "__main__":
    main()
