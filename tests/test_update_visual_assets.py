from pathlib import Path
import importlib.util
import unittest
from unittest.mock import patch

from PIL import Image, ImageChops


REPO_ROOT = Path(__file__).resolve().parents[1]

VISUAL_SCRIPT = (
    REPO_ROOT
    / "scripts"
    / "update_visual_assets.py"
)


def load_visual_module():
    spec = importlib.util.spec_from_file_location(
        "update_visual_assets_for_tests",
        VISUAL_SCRIPT,
    )

    if spec is None or spec.loader is None:
        raise RuntimeError(
            "Could not load update_visual_assets.py."
        )

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    return module


visuals = load_visual_module()


class VisualAssetTests(unittest.TestCase):
    def test_final_visual_settings(self):
        self.assertEqual(
            visuals.SOCIAL_BLUR_RADIUS,
            0.50,
        )

        self.assertEqual(
            visuals.NEXUS_CROP_TOP,
            120,
        )

        self.assertEqual(
            visuals.THUMBNAIL_SIZE,
            (960, 540),
        )

        self.assertEqual(
            visuals.SOCIAL_OUTPUT_SIZE,
            (1280, 640),
        )

        self.assertEqual(
            visuals.NEXUS_HEADER_SIZE,
            (1300, 372),
        )

    def test_social_output_applies_selected_blur(self):
        source = Image.new(
            "RGB",
            (1920, 960),
            "black",
        )

        for x in range(960, 1920):
            for y in range(960):
                source.putpixel(
                    (x, y),
                    (255, 255, 255),
                )

        with patch.object(
            visuals,
            "SOCIAL_BLUR_RADIUS",
            0.0,
        ):
            unblurred = (
                visuals.prepare_social_output(
                    source
                )
            )

        with patch.object(
            visuals,
            "SOCIAL_BLUR_RADIUS",
            0.50,
        ):
            blurred = (
                visuals.prepare_social_output(
                    source
                )
            )

        self.assertEqual(
            blurred.size,
            visuals.SOCIAL_OUTPUT_SIZE,
        )

        difference = ImageChops.difference(
            unblurred,
            blurred,
        )

        self.assertIsNotNone(
            difference.getbbox()
        )

    def test_nexus_crop_has_expected_size(self):
        master = Image.new(
            "RGB",
            visuals.SOCIAL_MASTER_SIZE,
            "black",
        )

        result = visuals.nexus_crop(
            master,
            visuals.NEXUS_CROP_TOP,
        )

        self.assertEqual(
            result.size,
            visuals.NEXUS_HEADER_SIZE,
        )


class VisualAssetWorkflowTests(unittest.TestCase):
    def test_workflow_covers_generation_contract(self):
        workflow = (
            REPO_ROOT
            / ".github"
            / "workflows"
            / "update_visual_assets.yml"
        ).read_text(
            encoding="utf-8"
        )

        for source in (
            'assets/thumbnail/thumbnail_background.png',
            'assets/thumbnail/thumbnail_title_overlay.png',
            'assets/community/github_social_title_overlay.png',
        ):
            self.assertIn(
                f'- "{source}"',
                workflow,
            )

        self.assertIn(
            '- "scripts/update_visual_assets.py"',
            workflow,
        )

        self.assertIn(
            '- "tests/test_update_visual_assets.py"',
            workflow,
        )

        self.assertIn(
            'python -m unittest discover -s tests '
            '-p "test_update_visual_assets.py"',
            workflow,
        )

        for generated in (
            "mod/thumbnail.png",
            "assets/community/github_social_preview.jpg",
            "assets/community/nexus_header.jpg",
        ):
            self.assertIn(
                f"git add {generated}",
                workflow,
            )

        self.assertNotIn(
            'thumbnail_source.png',
            workflow,
        )

        self.assertNotIn(
            '- "mod/thumbnail.png"',
            workflow,
        )

        self.assertNotIn(
            '- "assets/community/github_social_preview.jpg"',
            workflow,
        )

        self.assertNotIn(
            '- "assets/community/nexus_header.jpg"',
            workflow,
        )


if __name__ == "__main__":
    unittest.main()
