package processing

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
)

// Read only the bounded TIFF orientation tag. Other EXIF fields, including
// GPS coordinates, are discarded when NormalizeImage re-encodes the pixels.
func jpegOrientation(raw []byte) int {
	if len(raw) < 4 || raw[0] != 0xff || raw[1] != 0xd8 {
		return 1
	}
	for offset := 2; offset+4 <= len(raw); {
		if raw[offset] != 0xff {
			return 1
		}
		marker := raw[offset+1]
		if marker == 0xda || marker == 0xd9 {
			return 1
		}
		size := int(binary.BigEndian.Uint16(raw[offset+2 : offset+4]))
		if size < 2 || offset+2+size > len(raw) {
			return 1
		}
		segment := raw[offset+4 : offset+2+size]
		offset += 2 + size
		if marker != 0xe1 || !bytes.HasPrefix(segment, []byte("Exif\x00\x00")) {
			continue
		}
		tiff := segment[6:]
		if len(tiff) < 8 {
			return 1
		}
		var order binary.ByteOrder
		if string(tiff[:2]) == "II" {
			order = binary.LittleEndian
		} else if string(tiff[:2]) == "MM" {
			order = binary.BigEndian
		} else {
			return 1
		}
		if order.Uint16(tiff[2:4]) != 42 {
			return 1
		}
		start := uint64(order.Uint32(tiff[4:8]))
		if start+2 > uint64(len(tiff)) {
			return 1
		}
		count := int(order.Uint16(tiff[start : start+2]))
		if count > 4096 {
			return 1
		}
		for i := 0; i < count; i++ {
			at := start + 2 + uint64(i)*12
			if at+12 > uint64(len(tiff)) {
				return 1
			}
			tag := tiff[at : at+12]
			if order.Uint16(tag[:2]) == 0x112 && order.Uint16(tag[2:4]) == 3 && order.Uint32(tag[4:8]) == 1 {
				value := int(order.Uint16(tag[8:10]))
				if value >= 1 && value <= 8 {
					return value
				}
				return 1
			}
		}
	}
	return 1
}
func orientImage(src image.Image, orientation int) image.Image {
	if orientation <= 1 || orientation > 8 {
		return src
	}
	bounds := src.Bounds()
	w, h := bounds.Dx(), bounds.Dy()
	outW, outH := w, h
	if orientation >= 5 {
		outW, outH = h, w
	}
	return orientedImage{src: src, orientation: orientation, w: w, h: h, bounds: image.Rect(0, 0, outW, outH)}
}

// JPEG encoding reads transformed coordinates without allocating a second
// full-resolution RGBA buffer (up to another 96 MiB for a 24 MP input).
type orientedImage struct {
	src               image.Image
	orientation, w, h int
	bounds            image.Rectangle
}

func (v orientedImage) ColorModel() color.Model { return v.src.ColorModel() }
func (v orientedImage) Bounds() image.Rectangle { return v.bounds }
func (v orientedImage) At(x, y int) color.Color {
	sx, sy := x, y
	switch v.orientation {
	case 2:
		sx = v.w - 1 - x
	case 3:
		sx, sy = v.w-1-x, v.h-1-y
	case 4:
		sy = v.h - 1 - y
	case 5:
		sx, sy = y, x
	case 6:
		sx, sy = y, v.h-1-x
	case 7:
		sx, sy = v.w-1-y, v.h-1-x
	case 8:
		sx, sy = v.w-1-y, x
	}
	b := v.src.Bounds()
	return v.src.At(sx+b.Min.X, sy+b.Min.Y)
}
