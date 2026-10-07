from __future__ import annotations

from pathlib import Path
import argparse
import io
import re
import shutil
import sys

from PIL import Image, ImageChops, ImageFilter, ImageStat


REPO_ROOT = Path(__file__).resolve().parent.parent

THUMBNAIL_DIR = REPO_ROOT / "assets" / "thumbnail"
COMMUNITY_DIR = REPO_ROOT / "assets" / "community"

LOCAL_THUMBNAIL_DIR = (
    THUMBNAIL_DIR
    / "local"
    / "rendered"
)

LOCAL_SOCIAL_ROOT = (
    COMMUNITY_DIR
    / "local"
    / "github_social_preview"
)

PREVIEW_DIR = (
    REPO_ROOT
    / "development"
    / "local"
    / "visual-assets"
)


THUMBNAIL_BACKGROUND = (
    THUMBNAIL_DIR
    / "thumbnail_background.png"
)

THUMBNAIL_TITLE_OVERLAY = (
    THUMBNAIL_DIR
    / "thumbnail_title_overlay.png"
)

SOCIAL_TITLE_OVERLAY = (
    COMMUNITY_DIR
    / "github_social_title_overlay.png"
)

MOD_THUMBNAIL = (
    REPO_ROOT
    / "mod"
    / "thumbnail.png"
)

SOCIAL_PREVIEW = (
    COMMUNITY_DIR
    / "github_social_preview.jpg"
)

NEXUS_HEADER = (
    COMMUNITY_DIR
    / "nexus_header.jpg"
)

THUMBNAIL_SIZE = (960, 540)

SOCIAL_MASTER_SIZE = (1920, 960)
SOCIAL_OUTPUT_SIZE = (1280, 640)

SOCIAL_BLUR_RADIUS = 0.50

NEXUS_HEADER_SIZE = (1300, 372)

# Initial candidate. We will review the generated alternatives
# before treating this crop as final.
NEXUS_CROP_TOP = 120

# Use the stricter decimal interpretation of "1 MB".
MAX_PLATFORM_BYTES = 1_000_000

TITLE_FILL = (0xE2, 0xE2, 0xF4)
SHADOW_FILL = (0, 0, 0)

JPEG_MIN_QUALITY = 85

BLUR_CANDIDATES = (
    0.0,
    0.25,
    0.50,
    0.75,
)

HEADER_CROP_TOP_CANDIDATES = (
    100,
    120,
    140,
    160,
    180,
    200,
)


def fail(message: str) -> None:
    raise RuntimeError(message)


def latest_social_render() -> Path:
    if not LOCAL_SOCIAL_ROOT.is_dir():
        fail(
            "Local social preview directory not found: "
            f"{LOCAL_SOCIAL_ROOT}"
        )

    versions = []

    for path in LOCAL_SOCIAL_ROOT.iterdir():
        if not path.is_dir():
            continue

        match = re.fullmatch(
            r"v(\d+)",
            path.name,
            flags=re.IGNORECASE,
        )

        if match:
            versions.append(
                (
                    int(match.group(1)),
                    path,
                )
            )

    if not versions:
        fail(
            "No vN social preview directories found in: "
            f"{LOCAL_SOCIAL_ROOT}"
        )

    version_dir = max(
        versions,
        key=lambda item: item[0],
    )[1]

    render = (
        version_dir
        / "rendered"
        / "github_social_preview.png"
    )

    if not render.is_file():
        fail(
            "Unblurred social preview render not found: "
            f"{render}"
        )

    return render


def best_two_color_overlay(
    background: Image.Image,
    composite: Image.Image,
) -> Image.Image:
    background = background.convert("RGB")
    composite = composite.convert("RGB")

    if background.size != composite.size:
        fail(
            "Overlay extraction requires matching sizes: "
            f"{background.size} != {composite.size}"
        )

    difference = ImageChops.difference(
        background,
        composite,
    )

    bbox = difference.getbbox()

    overlay = Image.new(
        "RGBA",
        background.size,
        (0, 0, 0, 0),
    )

    if bbox is None:
        return overlay

    background_pixels = background.load()
    composite_pixels = composite.load()
    output_pixels = overlay.load()

    foregrounds = (
        TITLE_FILL,
        SHADOW_FILL,
    )

    left, top, right, bottom = bbox

    for y in range(top, bottom):
        for x in range(left, right):
            bg = background_pixels[x, y]
            result = composite_pixels[x, y]

            if bg == result:
                continue

            best_error = float("inf")
            best_alpha = 0.0
            best_foreground = TITLE_FILL

            for foreground in foregrounds:
                vector = tuple(
                    foreground[i] - bg[i]
                    for i in range(3)
                )

                delta = tuple(
                    result[i] - bg[i]
                    for i in range(3)
                )

                denominator = sum(
                    value * value
                    for value in vector
                )

                if denominator <= 1e-9:
                    continue

                alpha = (
                    sum(
                        delta[i] * vector[i]
                        for i in range(3)
                    )
                    / denominator
                )

                alpha = max(
                    0.0,
                    min(1.0, alpha),
                )

                prediction = tuple(
                    bg[i] * (1.0 - alpha)
                    + foreground[i] * alpha
                    for i in range(3)
                )

                error = sum(
                    (
                        prediction[i]
                        - result[i]
                    ) ** 2
                    for i in range(3)
                )

                if error < best_error:
                    best_error = error
                    best_alpha = alpha
                    best_foreground = foreground

            alpha_byte = round(
                best_alpha * 255
            )

            if alpha_byte > 0:
                output_pixels[x, y] = (
                    *best_foreground,
                    alpha_byte,
                )

    return overlay


def mean_absolute_difference(
    first: Image.Image,
    second: Image.Image,
) -> float:
    difference = ImageChops.difference(
        first.convert("RGB"),
        second.convert("RGB"),
    )

    means = ImageStat.Stat(
        difference
    ).mean

    return sum(means) / len(means)


def refresh_sources() -> None:
    local_master = (
        LOCAL_THUMBNAIL_DIR
        / "thumbnail(1920x1080).png"
    )

    local_background = (
        LOCAL_THUMBNAIL_DIR
        / "thumbnail_background(1920x1080).png"
    )

    if not local_master.is_file():
        fail(
            "Local thumbnail master not found: "
            f"{local_master}"
        )

    if not local_background.is_file():
        fail(
            "Local thumbnail background not found: "
            f"{local_background}"
        )

    social_render = latest_social_render()

    THUMBNAIL_DIR.mkdir(
        parents=True,
        exist_ok=True,
    )

    COMMUNITY_DIR.mkdir(
        parents=True,
        exist_ok=True,
    )


    shutil.copy2(
        local_background,
        THUMBNAIL_BACKGROUND,
    )

    with (
        Image.open(THUMBNAIL_BACKGROUND) as background_image,
        Image.open(local_master) as master_image,
    ):
        background = background_image.convert("RGB")
        master = master_image.convert("RGB")

        if (
            background.size != (1920, 1080)
            or master.size != (1920, 1080)
        ):
            fail(
                "Thumbnail source/background must "
                "both be 1920x1080."
            )

        overlay = best_two_color_overlay(
            background,
            master,
        )

        overlay.save(
            THUMBNAIL_TITLE_OVERLAY,
            format="PNG",
            optimize=True,
        )

        reconstructed = Image.alpha_composite(
            background.convert("RGBA"),
            overlay,
        ).convert("RGB")

        score = mean_absolute_difference(
            master,
            reconstructed,
        )

        if score > 0.75:
            fail(
                "Thumbnail overlay reconstruction "
                f"drift is too high: {score:.3f}"
            )

    with (
        Image.open(THUMBNAIL_BACKGROUND) as background_image,
        Image.open(social_render) as social_image,
    ):
        social_background = (
            background_image
            .convert("RGB")
            .crop(
                (
                    0,
                    0,
                    *SOCIAL_MASTER_SIZE,
                )
            )
        )

        social = social_image.convert("RGB")

        if social.size != SOCIAL_MASTER_SIZE:
            fail(
                "Social preview source must be "
                f"{SOCIAL_MASTER_SIZE[0]}x"
                f"{SOCIAL_MASTER_SIZE[1]}: "
                f"{social_render}"
            )

        overlay = best_two_color_overlay(
            social_background,
            social,
        )

        overlay.save(
            SOCIAL_TITLE_OVERLAY,
            format="PNG",
            optimize=True,
        )

        reconstructed = Image.alpha_composite(
            social_background.convert("RGBA"),
            overlay,
        ).convert("RGB")

        score = mean_absolute_difference(
            social,
            reconstructed,
        )

        if score > 0.75:
            fail(
                "Social overlay reconstruction "
                f"drift is too high: {score:.3f}"
            )


    print(
        "Refreshed: "
        f"{THUMBNAIL_BACKGROUND.relative_to(REPO_ROOT)}"
    )

    print(
        "Refreshed: "
        f"{THUMBNAIL_TITLE_OVERLAY.relative_to(REPO_ROOT)}"
    )

    print(
        "Refreshed: "
        f"{SOCIAL_TITLE_OVERLAY.relative_to(REPO_ROOT)}"
    )

    print(
        "Social source: "
        f"{social_render.relative_to(REPO_ROOT)}"
    )


def require_sources() -> None:
    required = (
        THUMBNAIL_BACKGROUND,
        THUMBNAIL_TITLE_OVERLAY,
        SOCIAL_TITLE_OVERLAY,
    )

    missing = [
        path
        for path in required
        if not path.is_file()
    ]

    if missing:
        formatted = "\n".join(
            f"- {path.relative_to(REPO_ROOT)}"
            for path in missing
        )

        fail(
            "Tracked visual sources are missing:\n"
            f"{formatted}\n"
            "Run with --refresh-sources locally first."
        )


def save_png_under_limit(
    image: Image.Image,
    path: Path,
    max_bytes: int,
) -> int:
    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    image.convert("RGB").save(
        path,
        format="PNG",
        optimize=True,
        compress_level=9,
    )

    size = path.stat().st_size

    if size > max_bytes:
        fail(
            f"PNG exceeds {max_bytes:,} bytes: "
            f"{path.relative_to(REPO_ROOT)} "
            f"= {size:,} bytes. "
            "Automatic lossy fallback is "
            "intentionally disabled."
        )

    return size


def encode_jpeg_under_limit(
    image: Image.Image,
    path: Path,
    max_bytes: int,
) -> tuple[int, int]:
    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    rgb = image.convert("RGB")

    for quality in range(
        100,
        JPEG_MIN_QUALITY - 1,
        -1,
    ):
        buffer = io.BytesIO()

        rgb.save(
            buffer,
            format="JPEG",
            quality=quality,
            subsampling=0,
            optimize=True,
            progressive=True,
        )

        data = buffer.getvalue()

        if len(data) <= max_bytes:
            path.write_bytes(data)

            return (
                quality,
                len(data),
            )

    fail(
        f"Could not encode {path.name} "
        f"under {max_bytes:,} bytes without "
        f"dropping below JPEG quality "
        f"{JPEG_MIN_QUALITY}."
    )


def thumbnail_master() -> Image.Image:
    with (
        Image.open(THUMBNAIL_BACKGROUND) as background_image,
        Image.open(THUMBNAIL_TITLE_OVERLAY) as overlay_image,
    ):
        background = background_image.convert("RGBA")
        overlay = overlay_image.convert("RGBA")

        expected_size = (1920, 1080)

        if background.size != expected_size:
            fail(
                "Thumbnail background must be "
                "1920x1080."
            )

        if overlay.size != expected_size:
            fail(
                "Thumbnail title overlay must be "
                "1920x1080."
            )

        return Image.alpha_composite(
            background,
            overlay,
        ).convert("RGB")

def social_master() -> Image.Image:
    with (
        Image.open(THUMBNAIL_BACKGROUND) as background_image,
        Image.open(SOCIAL_TITLE_OVERLAY) as overlay_image,
    ):
        background = (
            background_image
            .convert("RGBA")
            .crop(
                (
                    0,
                    0,
                    *SOCIAL_MASTER_SIZE,
                )
            )
        )

        overlay = overlay_image.convert("RGBA")

        if overlay.size != SOCIAL_MASTER_SIZE:
            fail(
                "Social title overlay must be "
                f"{SOCIAL_MASTER_SIZE[0]}x"
                f"{SOCIAL_MASTER_SIZE[1]}."
            )

        return Image.alpha_composite(
            background,
            overlay,
        ).convert("RGB")


def prepare_social_output(
    master: Image.Image,
) -> Image.Image:
    output = master.resize(
        SOCIAL_OUTPUT_SIZE,
        Image.Resampling.LANCZOS,
    )

    if SOCIAL_BLUR_RADIUS > 0:
        output = output.filter(
            ImageFilter.GaussianBlur(
                radius=SOCIAL_BLUR_RADIUS
            )
        )

    return output

def nexus_crop(
    master: Image.Image,
    top: int,
) -> Image.Image:
    source_width, source_height = master.size

    crop_height = round(
        source_width
        * NEXUS_HEADER_SIZE[1]
        / NEXUS_HEADER_SIZE[0]
    )

    if (
        top < 0
        or top + crop_height > source_height
    ):
        fail(
            f"Invalid Nexus crop top {top} "
            f"for source {master.size}."
        )

    cropped = master.crop(
        (
            0,
            top,
            source_width,
            top + crop_height,
        )
    )

    return cropped.resize(
        NEXUS_HEADER_SIZE,
        Image.Resampling.LANCZOS,
    )


def generate_previews(
    master: Image.Image,
) -> None:
    PREVIEW_DIR.mkdir(
        parents=True,
        exist_ok=True,
    )

    social_base = master.resize(
        SOCIAL_OUTPUT_SIZE,
        Image.Resampling.LANCZOS,
    )

    for radius in BLUR_CANDIDATES:
        if radius == 0:
            candidate = social_base
            name = (
                "github_social_preview-no-blur.jpg"
            )
        else:
            candidate = social_base.filter(
                ImageFilter.GaussianBlur(
                    radius=radius
                )
            )

            name = (
                "github_social_preview-"
                f"blur-{radius:.2f}.jpg"
            )

        encode_jpeg_under_limit(
            candidate,
            PREVIEW_DIR / name,
            MAX_PLATFORM_BYTES,
        )

    for top in HEADER_CROP_TOP_CANDIDATES:
        candidate = nexus_crop(
            master,
            top,
        )

        encode_jpeg_under_limit(
            candidate,
            PREVIEW_DIR
            / f"nexus_header-top-{top}.jpg",
            MAX_PLATFORM_BYTES,
        )


def generate(create_previews: bool = False) -> None:
    require_sources()

    source = thumbnail_master()

    thumbnail = source.resize(
        THUMBNAIL_SIZE,
        Image.Resampling.LANCZOS,
    )

    thumbnail_bytes = save_png_under_limit(
        thumbnail,
        MOD_THUMBNAIL,
        MAX_PLATFORM_BYTES,
    )

    master = social_master()

    social = prepare_social_output(
        master
    )

    (
        social_quality,
        social_bytes,
    ) = encode_jpeg_under_limit(
        social,
        SOCIAL_PREVIEW,
        MAX_PLATFORM_BYTES,
    )

    header = nexus_crop(
        master,
        NEXUS_CROP_TOP,
    )

    (
        header_quality,
        header_bytes,
    ) = encode_jpeg_under_limit(
        header,
        NEXUS_HEADER,
        MAX_PLATFORM_BYTES,
    )

    if create_previews:
        generate_previews(master)

    print()
    print("Generated visual assets:")

    print(
        "- "
        f"{MOD_THUMBNAIL.relative_to(REPO_ROOT)}: "
        f"{THUMBNAIL_SIZE[0]}x{THUMBNAIL_SIZE[1]}, "
        f"{thumbnail_bytes:,} bytes"
    )

    print(
        "- "
        f"{SOCIAL_PREVIEW.relative_to(REPO_ROOT)}: "
        f"{SOCIAL_OUTPUT_SIZE[0]}x"
        f"{SOCIAL_OUTPUT_SIZE[1]}, "
        f"JPEG q{social_quality}, "
        f"{social_bytes:,} bytes"
    )

    print(
        "- "
        f"{NEXUS_HEADER.relative_to(REPO_ROOT)}: "
        f"{NEXUS_HEADER_SIZE[0]}x"
        f"{NEXUS_HEADER_SIZE[1]}, "
        f"crop top {NEXUS_CROP_TOP}, "
        f"JPEG q{header_quality}, "
        f"{header_bytes:,} bytes"
    )

    if create_previews:
        print(
            "- Local comparison candidates: "
            f"{PREVIEW_DIR.relative_to(REPO_ROOT)}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Generate CK3 mod and storefront "
            "visual assets."
        )
    )

    parser.add_argument(
        "--refresh-sources",
        action="store_true",
        help=(
            "Refresh tracked visual sources from "
            "ignored local rendered files before "
            "generation."
        ),
    )

    parser.add_argument(
        "--review",
        action="store_true",
        help=(
            "Generate local visual comparison "
            "candidates in addition to final assets."
        ),
    )
    args = parser.parse_args()

    try:
        if args.refresh_sources:
            refresh_sources()

        generate(args.review)

        return 0

    except Exception as error:
        print(
            f"Error: {error}",
            file=sys.stderr,
        )

        return 1


if __name__ == "__main__":
    raise SystemExit(main())
