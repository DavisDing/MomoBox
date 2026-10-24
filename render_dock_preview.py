import os
import math
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 1680, 1600
canvas = Image.new("RGBA", (W, H), (242, 244, 248, 255))

font_pf = "/System/Library/Fonts/PingFang.ttc"
font_sf = "/System/Library/Fonts/SFNS.ttf"

def get_font(size, bold=False):
    try:
        idx = 2 if bold else 0
        return ImageFont.truetype(font_pf, size, index=idx)
    except:
        try:
            return ImageFont.truetype(font_sf, size)
        except:
            return ImageFont.load_default()

def draw_pill(d, bbox, fill, outline=None, width=1):
    x0, y0, x1, y1 = bbox
    r = (y1 - y0) / 2
    d.rounded_rectangle([x0, y0, x1, y1], radius=r, fill=fill, outline=outline, width=width)

def draw_device_mockup(canvas, origin_x, origin_y, title, is_dark=False, is_batch=False):
    # Phone dimensions: 430 x 932 (scaled x 1.4 -> 602 x 1305)
    pw, ph = 620, 1340
    px, py = origin_x, origin_y
    
    # Outer device shadow
    shadow_img = Image.new("RGBA", (W, H), (0,0,0,0))
    sdraw = ImageDraw.Draw(shadow_img)
    sdraw.rounded_rectangle([px+8, py+14, px+pw-8, py+ph+14], radius=54, fill=(0, 0, 0, 45 if not is_dark else 70))
    shadow_blur = shadow_img.filter(ImageFilter.GaussianBlur(32))
    canvas.alpha_composite(shadow_blur)
    
    # Device Frame
    fdraw = ImageDraw.Draw(canvas)
    frame_color = (25, 27, 31, 255) if is_dark else (220, 224, 230, 255)
    body_color = (15, 17, 21, 255) if is_dark else (248, 249, 252, 255)
    fdraw.rounded_rectangle([px, py, px+pw, py+ph], radius=52, fill=frame_color)
    
    # Screen inner
    sx, sy, sw, sh = px+10, py+10, pw-20, ph-20
    
    # Generate screen content with subtle background aura / wallpapers for glassmorphism
    screen = Image.new("RGBA", (sw, sh), body_color)
    s_draw = ImageDraw.Draw(screen)
    
    # Decorative mesh gradient circles inside screen to show transparency/blur
    if not is_dark:
        # soft blue and lavender glows
        glow = Image.new("RGBA", (sw, sh), (0,0,0,0))
        gdraw = ImageDraw.Draw(glow)
        gdraw.ellipse([sw-300, 180, sw+150, 600], fill=(10, 132, 255, 38))
        gdraw.ellipse([-100, 500, 320, 920], fill=(255, 159, 10, 30))
        gdraw.ellipse([100, 850, 500, 1250], fill=(48, 209, 88, 30))
        glow = glow.filter(ImageFilter.GaussianBlur(80))
        screen.alpha_composite(glow)
    else:
        glow = Image.new("RGBA", (sw, sh), (0,0,0,0))
        gdraw = ImageDraw.Draw(glow)
        gdraw.ellipse([sw-320, 150, sw+100, 580], fill=(10, 132, 255, 55))
        gdraw.ellipse([-80, 520, 320, 920], fill=(191, 90, 242, 45))
        gdraw.ellipse([80, 880, 480, 1280], fill=(10, 132, 255, 45))
        glow = glow.filter(ImageFilter.GaussianBlur(90))
        screen.alpha_composite(glow)

    # Status Bar
    time_color = (255, 255, 255, 230) if is_dark else (20, 20, 22, 230)
    s_draw.text((38, 18), "9:41", font=get_font(20, bold=True), fill=time_color)
    # Dynamic Island
    s_draw.rounded_rectangle([sw/2 - 70, 14, sw/2 + 70, 48], radius=17, fill=(0, 0, 0, 255))
    # Battery & signals
    s_draw.rounded_rectangle([sw - 68, 22, sw - 40, 38], radius=4, outline=time_color, width=2)
    s_draw.rounded_rectangle([sw - 65, 25, sw - 48, 35], radius=2, fill=time_color)
    s_draw.rectangle([sw - 39, 27, sw - 37, 33], fill=time_color)

    # 1. Top Bar (System Glassmorphism)
    topbar_y = 62
    topbar_bg = (30, 32, 38, 180) if is_dark else (255, 255, 255, 190)
    topbar_border = (255, 255, 255, 28) if is_dark else (0, 0, 0, 15)
    
    # Title & Location Switcher
    s_draw.text((36, topbar_y + 4), "MomoBox", font=get_font(28, bold=True), fill=(255, 255, 255) if is_dark else (15, 17, 21))
    s_draw.text((170, topbar_y + 12), "主卧 · 智能空间", font=get_font(16), fill=(255, 255, 255, 150) if is_dark else (100, 105, 115))
    
    # Search Box (Glass Capsule)
    search_y = topbar_y + 54
    search_bg = (255, 255, 255, 25) if is_dark else (118, 118, 128, 28)
    draw_pill(s_draw, [36, search_y, sw - 36, search_y + 48], fill=search_bg, outline=topbar_border, width=1)
    # Search icon & placeholder
    s_draw.ellipse([54, search_y + 16, 68, search_y + 30], outline=(140, 145, 155), width=2)
    s_draw.line([66, search_y + 28, 74, search_y + 36], fill=(140, 145, 155), width=2)
    s_draw.text((86, search_y + 13), "搜索物品、智能空间或即将过期...", font=get_font(16), fill=(140, 145, 155))

    # Content: Status summary cards (Glass cards)
    card_y = search_y + 68
    card_bg = (32, 34, 42, 190) if is_dark else (255, 255, 255, 210)
    card_border = (255, 255, 255, 30) if is_dark else (255, 255, 255, 200)
    
    # 2 Stat cards side by side
    card_w = (sw - 72 - 16) / 2
    # Card 1: 临期提醒
    s_draw.rounded_rectangle([36, card_y, 36 + card_w, card_y + 100], radius=22, fill=card_bg, outline=card_border, width=1)
    s_draw.text((54, card_y + 18), "临期告警", font=get_font(15), fill=(255, 69, 58) if is_dark else (215, 45, 35))
    s_draw.text((54, card_y + 46), "3", font=get_font(34, bold=True), fill=(255, 255, 255) if is_dark else (20, 22, 28))
    s_draw.text((80, card_y + 58), "件需尽快处理", font=get_font(14), fill=(140, 145, 155))
    
    # Card 2: 空间负荷
    s_draw.rounded_rectangle([36 + card_w + 16, card_y, sw - 36, card_y + 100], radius=22, fill=card_bg, outline=card_border, width=1)
    s_draw.text((36 + card_w + 34, card_y + 18), "物品总储", font=get_font(15), fill=(10, 132, 255))
    s_draw.text((36 + card_w + 34, card_y + 46), "142", font=get_font(34, bold=True), fill=(255, 255, 255) if is_dark else (20, 22, 28))
    s_draw.text((36 + card_w + 98, card_y + 58), "件在库", font=get_font(14), fill=(140, 145, 155))

    # Items section heading
    s_draw.text((38, card_y + 120), "最近收纳与常备物品", font=get_font(19, bold=True), fill=(255, 255, 255) if is_dark else (22, 24, 28))
    s_draw.text((sw - 100, card_y + 122), "批量管理", font=get_font(15, bold=True), fill=(10, 132, 255))

    # Item List Cards (Notice how items naturally scroll *behind* the floating dock!)
    items = [
        {"title": "日式无印纯棉毛巾 (3条装)", "sub": "主卧衣帽间 · 二层抽屉 #02", "tag": "常温干燥", "days": "常备", "days_color": (120, 125, 135)},
        {"title": "澳洲进口深海鱼油软胶囊", "sub": "客厅茶几药箱 · 保健格", "tag": "冷藏储鲜", "days": "剩 4 天", "days_color": (255, 69, 58)},
        {"title": "飞利浦声波电动牙刷替换刷头", "sub": "主卫置物镜柜 · 左侧", "tag": "耗材备用", "days": "4 支存", "days_color": (10, 132, 255)},
        {"title": "N95 医用防护口罩 (50只)", "sub": "玄关储物柜 · 上层置物盒", "tag": "应急常备", "days": "充足", "days_color": (48, 209, 88)},
        {"title": "Type-C 编织快充数据线 2m", "sub": "书房数码理线盒 · 抽屉A", "tag": "数码配件", "days": "常备", "days_color": (120, 125, 135)},
        {"title": "日本进口炭疽除湿除臭剂", "sub": "次卧衣柜底部 · 防潮", "tag": "季节用品", "days": "剩 12 天", "days_color": (255, 159, 10)},
        {"title": "依云天然矿泉水 500ml*24", "sub": "阳台储藏间 · 饮用水架", "tag": "食品饮料", "days": "剩 1 箱", "days_color": (120, 125, 135)},
    ]

    list_y = card_y + 160
    for i, itm in enumerate(items):
        iy = list_y + i * 94
        if iy > sh - 40:
            break
        # Card
        s_draw.rounded_rectangle([36, iy, sw - 36, iy + 82], radius=18, fill=card_bg, outline=card_border, width=1)
        # Category icon square
        icon_bg = (10, 132, 255, 25) if not is_dark else (255, 255, 255, 20)
        s_draw.rounded_rectangle([50, iy + 17, 98, iy + 65], radius=12, fill=icon_bg)
        # Inner glyph hint
        s_draw.rectangle([66, iy + 33, 82, iy + 49], outline=(10, 132, 255) if not is_dark else (255, 255, 255, 200), width=2)
        
        # Texts
        s_draw.text((112, iy + 16), itm["title"], font=get_font(16, bold=True), fill=(255, 255, 255) if is_dark else (24, 26, 30))
        s_draw.text((112, iy + 46), itm["sub"], font=get_font(13), fill=(140, 145, 155))
        
        # Right tag
        tag_w = 70
        draw_pill(s_draw, [sw - 50 - tag_w, iy + 26, sw - 50, iy + 56], fill=(0,0,0,10) if not is_dark else (255,255,255,15))
        s_draw.text((sw - 50 - tag_w + 14, iy + 32), itm["days"], font=get_font(13, bold=True), fill=itm["days_color"])

    # -------------------------------------------------------------
    # 核心差异演示：悬浮式操作层 (Floating Glass Layer)
    # -------------------------------------------------------------
    
    if is_batch:
        # 1. 批量操作场景 (Batch Action Mode)
        # 遮罩层：高斯磨砂遮罩 (Mask dimming + blur)
        mask = Image.new("RGBA", (sw, sh), (0, 0, 0, 110 if not is_dark else 150))
        screen.alpha_composite(mask)
        
        # 悬浮在底部的批量操作栏 (Floating Action Bar / Pill Capsule)
        # 左右留边距 (32dp), 离底部有明显悬浮间隙 (40dp)
        dock_w = sw - 64
        dock_h = 76
        dock_x = 32
        dock_y = sh - dock_h - 44  # 悬浮不贴底！
        
        # 柔和扩散弥散投影 (Soft diffused shadow)
        dock_shadow = Image.new("RGBA", (sw, sh), (0,0,0,0))
        d_sdraw = ImageDraw.Draw(dock_shadow)
        d_sdraw.rounded_rectangle([dock_x + 4, dock_y + 8, dock_x + dock_w - 4, dock_y + dock_h + 16], radius=38, fill=(0, 0, 0, 80))
        dock_shadow = dock_shadow.filter(ImageFilter.GaussianBlur(24))
        screen.alpha_composite(dock_shadow)
        
        # 玻璃拟态本体 (Capsule with backdrop-blur & thin glow border)
        dock_canvas = Image.new("RGBA", (sw, sh), (0,0,0,0))
        d_cdraw = ImageDraw.Draw(dock_canvas)
        glass_fill = (255, 255, 255, 215) if not is_dark else (38, 42, 50, 220)
        border_glow = (255, 255, 255, 240) if not is_dark else (255, 255, 255, 45)
        
        draw_pill(d_cdraw, [dock_x, dock_y, dock_x + dock_w, dock_y + dock_h], fill=glass_fill, outline=border_glow, width=1)
        screen.alpha_composite(dock_canvas)
        
        # 内部横向等距排列 5 个操作项 (发送、编辑、移动、删除、更多)
        actions = [
            {"label": "发送分享", "color": (30, 32, 36) if not is_dark else (240, 240, 245)},
            {"label": "批量编辑", "color": (30, 32, 36) if not is_dark else (240, 240, 245)},
            {"label": "移动储位", "color": (30, 32, 36) if not is_dark else (240, 240, 245)},
            {"label": "消耗扣减", "color": (30, 32, 36) if not is_dark else (240, 240, 245)},
            {"label": "删除", "color": (255, 69, 58)},
        ]
        
        slot_w = dock_w / len(actions)
        for idx, act in enumerate(actions):
            cx = dock_x + slot_w * (idx + 0.5)
            cy = dock_y + 26
            
            # Simple clean linear icon representation
            if idx == 0: # Share
                s_draw.rectangle([cx - 8, cy - 8, cx + 8, cy + 8], outline=act["color"], width=2)
                s_draw.line([cx, cy - 12, cx, cy], fill=act["color"], width=2)
                s_draw.line([cx - 4, cy - 8, cx, cy - 12], fill=act["color"], width=2)
                s_draw.line([cx + 4, cy - 8, cx, cy - 12], fill=act["color"], width=2)
            elif idx == 1: # Edit
                s_draw.line([cx - 8, cy + 8, cx + 8, cy - 8], fill=act["color"], width=2)
                s_draw.rectangle([cx + 4, cy - 10, cx + 10, cy - 4], outline=act["color"], width=1)
            elif idx == 2: # Move
                s_draw.rectangle([cx - 9, cy - 9, cx + 9, cy + 9], outline=act["color"], width=2)
                s_draw.line([cx - 9, cy, cx + 9, cy], fill=act["color"], width=1)
            elif idx == 3: # Consume
                s_draw.ellipse([cx - 8, cy - 8, cx + 8, cy + 8], outline=act["color"], width=2)
                s_draw.line([cx - 4, cy, cx + 4, cy], fill=act["color"], width=2)
            elif idx == 4: # Delete
                s_draw.rectangle([cx - 7, cy - 5, cx + 7, cy + 9], outline=act["color"], width=2)
                s_draw.line([cx - 10, cy - 5, cx + 10, cy - 5], fill=act["color"], width=2)
                s_draw.line([cx - 4, cy - 8, cx + 4, cy - 8], fill=act["color"], width=1)
            
            # Label
            s_draw.text((cx - 24, cy + 18), act["label"], font=get_font(12, bold=True), fill=act["color"])
            
        # Top banner for batch hint
        draw_pill(s_draw, [sw/2 - 90, 80, sw/2 + 90, 118], fill=(0,0,0,180) if not is_dark else (255,255,255,220))
        s_draw.text((sw/2 - 60, 89), "已选择 2 项物品", font=get_font(14, bold=True), fill=(255,255,255) if not is_dark else (15,15,15))
        
    else:
        # 2. 常态悬浮导航底栏 (Floating Island Dock / Navigation Bar)
        # 彻底抛弃贴底白条！左右留边距 (28dp), 悬浮在 Home Indicator 上方 36dp
        dock_w = sw - 56
        dock_h = 72
        dock_x = 28
        dock_y = sh - dock_h - 48
        
        # 柔和扩散弥散投影 (Soft diffused shadow)
        dock_shadow = Image.new("RGBA", (sw, sh), (0,0,0,0))
        d_sdraw = ImageDraw.Draw(dock_shadow)
        d_sdraw.rounded_rectangle([dock_x + 6, dock_y + 10, dock_x + dock_w - 6, dock_y + dock_h + 16], radius=36, fill=(0, 0, 0, 50 if not is_dark else 75))
        dock_shadow = dock_shadow.filter(ImageFilter.GaussianBlur(26))
        screen.alpha_composite(dock_shadow)
        
        # 玻璃拟态本体胶囊 (Floating Capsule)
        dock_canvas = Image.new("RGBA", (sw, sh), (0,0,0,0))
        d_cdraw = ImageDraw.Draw(dock_canvas)
        # 75%~85% 半透明白/深灰毛玻璃
        glass_fill = (255, 255, 255, 215) if not is_dark else (34, 37, 44, 215)
        border_glow = (255, 255, 255, 230) if not is_dark else (255, 255, 255, 45)
        
        draw_pill(d_cdraw, [dock_x, dock_y, dock_x + dock_w, dock_y + dock_h], fill=glass_fill, outline=border_glow, width=1)
        screen.alpha_composite(dock_canvas)
        
        # Tab Items: 首页, 空间, [+入库高亮胶囊], 采买, 我的
        tabs = [
            {"name": "首页", "active": True},
            {"name": "空间", "active": False},
            {"name": "入库", "special": True},
            {"name": "采买", "active": False},
            {"name": "设置", "active": False},
        ]
        
        slot_w = dock_w / len(tabs)
        for idx, tab in enumerate(tabs):
            cx = dock_x + slot_w * (idx + 0.5)
            cy = dock_y + 24
            
            if tab.get("special"):
                # HyperOS × iOS 融合风格核心：居中悬浮极简胶囊快捷键
                btn_r = 24
                # 纯黑（深色模式纯白）
                btn_fill = (20, 22, 26) if not is_dark else (250, 250, 255)
                plus_color = (255, 255, 255) if not is_dark else (20, 22, 26)
                
                # Button circle
                s_draw.ellipse([cx - btn_r, dock_y + 12, cx + btn_r, dock_y + 12 + 2*btn_r], fill=btn_fill)
                # Plus icon
                s_draw.line([cx - 9, dock_y + 36, cx + 9, dock_y + 36], fill=plus_color, width=3)
                s_draw.line([cx, dock_y + 27, cx, dock_y + 45], fill=plus_color, width=3)
                continue
                
            is_act = tab.get("active", False)
            act_color = (10, 132, 255) if is_act else ((140, 145, 155) if not is_dark else (160, 165, 175))
            
            # Simple modern icons
            if idx == 0: # Home
                # Modern house shape
                s_draw.line([cx - 9, cy, cx, cy - 8], fill=act_color, width=2)
                s_draw.line([cx, cy - 8, cx + 9, cy], fill=act_color, width=2)
                s_draw.rectangle([cx - 7, cy, cx + 7, cy + 9], fill=act_color if is_act else None, outline=act_color, width=2)
            elif idx == 1: # Space/Boxes
                s_draw.rectangle([cx - 8, cy - 6, cx + 8, cy + 8], outline=act_color, width=2)
                s_draw.line([cx - 8, cy - 1, cx + 8, cy - 1], fill=act_color, width=1)
            elif idx == 3: # Cart/Buy
                s_draw.rectangle([cx - 8, cy - 4, cx + 8, cy + 8], outline=act_color, width=2)
                s_draw.line([cx - 4, cy - 4, cx - 4, cy - 8], fill=act_color, width=2)
                s_draw.line([cx + 4, cy - 4, cx + 4, cy - 8], fill=act_color, width=2)
                s_draw.line([cx - 4, cy - 8, cx + 4, cy - 8], fill=act_color, width=2)
            elif idx == 4: # Settings
                s_draw.ellipse([cx - 7, cy - 6, cx + 7, cy + 8], outline=act_color, width=2)
                s_draw.ellipse([cx - 3, cy - 2, cx + 3, cy + 4], fill=act_color)
            
            # Label
            s_draw.text((cx - 12, cy + 18), tab["name"], font=get_font(11, bold=is_act), fill=act_color)

    # Home Indicator at bottom
    indicator_y = sh - 18
    ind_color = (255, 255, 255, 100) if is_dark else (0, 0, 0, 70)
    draw_pill(s_draw, [sw/2 - 68, indicator_y, sw/2 + 68, indicator_y + 5], fill=ind_color)

    # Paste completed screen onto canvas
    canvas.paste(screen, (sx, sy))
    
    # Outer title header above device
    tdraw = ImageDraw.Draw(canvas)
    tdraw.text((px + 20, py - 60), title, font=get_font(24, bold=True), fill=(20, 24, 30))


# Generate 2 side-by-side screens:
# 1. Light Mode: Floating Navigation Capsule Dock (常态悬浮胶囊底栏，透出后方滚动列表)
# 2. Dark Mode: Floating Batch Action Bar (批量操作悬浮胶囊栏，背景压暗高斯模糊)

draw_device_mockup(canvas, 140, 150, "【浅色常态】悬浮式毛玻璃胶囊底栏（Floating Capsule Dock）", is_dark=False, is_batch=False)
draw_device_mockup(canvas, 920, 150, "【深色模式】批量管理悬浮操作栏（Floating Action Bar）", is_dark=True, is_batch=True)

# Add Top Banner Description
top_draw = ImageDraw.Draw(canvas)
top_draw.text((140, 42), "HyperOS × iOS 融合风格 · 悬浮毛玻璃底栏体系规范", font=get_font(30, bold=True), fill=(18, 20, 24))
top_draw.text((140, 82), "彻底抛弃贴底通栏传统底栏：左右留白 28dp、离底 48dp、圆角 36dp 胶囊形容器，85% 白色/深色毛玻璃，内容自然穿透底层", font=get_font(16), fill=(100, 105, 115))

os.makedirs("mockups/preview", exist_ok=True)
out_path = "mockups/preview/momo_floating_dock_preview.png"
canvas.save(out_path, quality=95)
print(f"Rendered successfully to {out_path}")
