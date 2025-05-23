from PIL import Image


def remove_black_background(input_path, output_path):
    # Open image and convert to RGBA (adds alpha channel if needed)
    img = Image.open(input_path).convert("RGBA")
    pixels = list(img.getdata())

    # Get distinct colors
    distinct_colors = set(pixels)
    print(f"Found {len(distinct_colors)} distinct colors:")
    for color in distinct_colors:
        print(color)

    # Build new pixel list: any pure-black RGB becomes fully transparent
    new_pixels = [
        (r, g, b, 0) if (r, g, b) == (0, 0, 0) else (r, g, b, a)
        for (r, g, b, a) in pixels
    ]

    # Apply and save
    img.putdata(new_pixels)
    img.save(output_path, "PNG")
    print(f"Saved transparent-background image to {output_path}")


if __name__ == "__main__":
    # Replace 'input.png' and 'output.png' with your filenames
    remove_black_background("input.png", "output.png")
