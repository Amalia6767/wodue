#!/usr/bin/env python3
"""Render self-contained README SVGs from the approved vector brand assets.

These are interface illustrations with fictional data, not app screenshots.
Run from any directory; no image service, font download or private data needed.
"""
from pathlib import Path
from html import escape
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / 'docs'
INK, CORAL, PAPER, MUTED = '#332D3D', '#CA5140', '#F8F5F0', '#756D7E'
FONT = "-apple-system,BlinkMacSystemFont,'PingFang SC','Microsoft YaHei',sans-serif"


def rect(x, y, w, h, fill='white', r=14, extra=''):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" {extra}/>'


def text(x, y, content, size=16, fill=INK, weight=400, extra=''):
    return f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" font-weight="{weight}" {extra}>{escape(content)}</text>'


def line(x1, y1, x2, y2, stroke='#E4DEE5', width=1, extra=''):
    return f'<path d="M{x1} {y1}H{x2}" stroke="{stroke}" stroke-width="{width}" {extra}/>' if y1 == y2 else f'<path d="M{x1} {y1}L{x2} {y2}" stroke="{stroke}" stroke-width="{width}" {extra}/>'


def circle(x, y, radius, fill='none', stroke='none', width=1):
    return f'<circle cx="{x}" cy="{y}" r="{radius}" fill="{fill}" stroke="{stroke}" stroke-width="{width}"/>'


def check(x, y, stroke='white', scale=1):
    return f'<path d="M{x-5*scale} {y}l{4*scale} {4*scale} {8*scale} {-9*scale}" fill="none" stroke="{stroke}" stroke-width="{2*scale}" stroke-linecap="round" stroke-linejoin="round"/>'


def logo(x, y, w, h, symbol=False):
    source = ROOT / 'Resources/Brand' / ('WoDueSymbol.svg' if symbol else 'WoDueWordmark.svg')
    root = ET.fromstring(source.read_text())
    # Inline paths, rather than external SVG references, work with GitHub's image proxy.
    paths = ''.join(ET.tostring(p, encoding='unicode') for p in root if p.tag.endswith('path'))
    return f'<svg x="{x}" y="{y}" width="{w}" height="{h}" viewBox="{root.attrib["viewBox"]}">{paths}</svg>'


def button(x, y, w, label, primary=False, h=42):
    return rect(x, y, w, h, INK if primary else '#FFFFFF', 11, 'stroke="#E4DEE5"') + text(x+w/2, y+h/2+6, label, 16, 'white' if primary else INK, 600, 'text-anchor="middle"')


def pill(x, y, w, label, fill='#ECE6F0', color=INK):
    return rect(x, y, w, 27, fill, 8) + text(x+w/2, y+19, label, 13, color, 600, 'text-anchor="middle"')


def write(name, w, h, title, description, elements, defs=''):
    document = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" aria-labelledby="title description">
<title id="title">{escape(title)}</title><desc id="description">{escape(description)}</desc>
<defs>{defs}</defs><g font-family="{FONT}">{''.join(elements)}</g></svg>\n'''
    ET.fromstring(document)
    (DOCS / name).write_text(document)


def brand_header():
    e = [rect(0, 0, 1200, 290, PAPER, 26), logo(48, 31, 360, 152),
         text(470, 92, 'DDL 别丢，生活照过。', 35, INK, 650),
         text(472, 136, '把未来的节点，变成今天能推进的一小段。', 20, MUTED),
         text(472, 177, 'WoDue · macOS 桌面计划与专注', 16, MUTED),
         line(52, 212, 1148, 212),
         text(54, 252, '收集节点', 17, INK, 600), text(224, 252, '→', 20, CORAL),
         text(304, 252, '安排时间', 17, INK, 600), text(474, 252, '→', 20, CORAL),
         text(554, 252, '专注与休息', 17, INK, 600), text(756, 252, '→', 20, CORAL),
         text(838, 252, '看见投入与进展', 17, INK, 600)]
    write('brand-header.svg', 1200, 290, '我Due！· WoDue', '紫墨与珊瑚色的我Due标志：字母 u 是会说话的嘴，上方水滴也是感叹号。', e)


def workbench():
    defs = '''<linearGradient id="ambient" x2="1" y2="1"><stop stop-color="#F4F0F3"/><stop offset=".55" stop-color="#F8E9E5"/><stop offset="1" stop-color="#EDE6F1"/></linearGradient>
<filter id="shadow" x="-10%" y="-10%" width="120%" height="130%"><feDropShadow dx="0" dy="9" stdDeviation="12" flood-color="#332D3D" flood-opacity=".08"/></filter>
<clipPath id="cup"><path d="M1256 349v64c0 40 72 40 72 0v-64Z"/></clipPath>'''
    e = [rect(0, 0, 1600, 1160, PAPER, 28), logo(30, 12, 280, 118),
         text(330, 69, '为这一天，排一点节奏。', 29, INK, 650),
         text(330, 102, '先看节点，再安排时间；专注一会儿，也好好休息。', 17, MUTED),
         pill(1304, 56, 240, '新版界面示意 · 虚构日程'),
         rect(24, 142, 1552, 922, 'url(#ambient)', 24, 'stroke="white" filter="url(#shadow)"'),
         rect(24, 142, 258, 922, '#F1EDF2', 24, 'fill-opacity=".85"'),
         line(282, 166, 282, 1040, '#DED7E3')]
    for i in range(3):
        e.append(circle(48+i*22, 167, 6, '#DED7E2'))
    e += [logo(43, 197, 165, 70), text(52, 280, '给每一天，留一点余地。', 13, MUTED),
          text(52, 315, '今天', 13, MUTED), rect(40, 329, 226, 48, INK, 13),
          text(61, 360, '☀', 21, '#E6AB9F'), text(95, 360, '今日节奏', 18, 'white', 600),
          pill(218, 340, 32, '4', '#57505F', 'white'), text(52, 421, '规划', 13, MUTED)]
    for y, label, glyph in [(460, '长期项目', '⚑'), (522, '节点与截止', '◷'), (584, '这几天', '▥')]:
        e += [text(61, y, glyph, 21, INK), text(95, y, label, 18, INK, 500)]
    e += [pill(207, 500, 45, '2 项', '#F4DEDA', '#9E3B2C'), text(52, 645, '整理', 13, MUTED),
          text(61, 685, '▤', 20), text(95, 685, '全部事项', 18, INK, 500),
          text(52, 785, '2026 年 11 月', 16, INK, 600), text(233, 785, '‹   ›', 17, MUTED),
          text(53, 826, '一    二    三    四    五    六    日', 13, MUTED)]
    for row in range(4):
        for col in range(7):
            day = 2+row*7+col
            if day == 2:
                e.append(rect(45+col*30, 842+row*35, 27, 28, INK, 8))
            e.append(text(58+col*30, 862+row*35, str(day), 13, 'white' if day == 2 else MUTED, 500, 'text-anchor="middle"'))
    e += [text(52, 1035, '粘贴识别   ·   日历同步', 13, MUTED),
          text(310, 205, '今日节奏', 12, CORAL, 650, 'letter-spacing="2"'),
          text(310, 242, '11 月 2 日 · 星期一', 30, INK, 650),
          button(687, 207, 34, '‹', h=34), button(729, 207, 34, '›', h=34),
          button(1318, 202, 108, '＋ 新事项'), button(1438, 202, 112, '安排时间'),
          rect(310, 270, 900, 220, '#FFFDFB', 20, 'fill-opacity=".82" stroke="white"'),
          pill(334, 291, 49, '现在', CORAL, 'white'), text(397, 311, '13:30–15:00 · 作业', 15, MUTED),
          rect(957, 289, 171, 36, '#EBE4E9', 10),
          text(971, 313, '25 / 5', 14, MUTED, 500),
          rect(1035, 292, 88, 30, 'white', 8), text(1051, 313, '50 / 10', 14, INK, 600),
          text(1168, 310, '···', 21, INK, 600),
          text(334, 359, '研究报告 · 整理材料与提纲', 27, INK, 650),
          button(334, 383, 208, '▶ 开始专注   40:00', True, 48),
          button(555, 383, 134, '完成这段', h=48), text(710, 413, '还剩 40 分钟，之后留白 30 分钟', 15, MUTED),
          rect(311, 447, 898, 42, '#F6E6E2', 14), logo(326, 449, 32, 32, True),
          text(365, 474, '离「交互原型提交」还有 2 天，今天推进一点就好。', 15, '#9E3B2C'),
          rect(1230, 270, 320, 220, '#FFFDFB', 20, 'fill-opacity=".82" stroke="white"'),
          text(1252, 310, '今天的 u 杯', 18, INK, 600),
          text(1252, 335, '完成一段，满一点', 12, MUTED),
          '<g clip-path="url(#cup)"><path d="M1250 423Q1270 410 1290 424T1336 421V465H1250Z" fill="#E5A194"/><path d="M1250 435Q1270 424 1290 437T1336 430V465H1250Z" fill="#CA5140"/></g>',
          '<path d="M1256 354v59c0 47 72 47 72 0v-59" fill="none" stroke="#332D3D" stroke-width="6" stroke-linecap="round"/>',
          text(1360, 394, '25%', 44, INK, 600), text(1360, 428, '已完成 1 小时', 15, INK, 600), text(1360, 454, '计划 4 小时', 14, MUTED),
          rect(310, 512, 1240, 177, '#FFFDFB', 19, 'fill-opacity=".75" stroke="white"'),
          text(330, 546, '一天的动线', 17, INK, 600)]
    for x, color, label in [(485, INK, '进行中'), (609, '#A298AD', '待做'), (719, '#DED8E4', '已完成 / 休息')]:
        e += [rect(x, 534, 20, 9, color, 3), text(x+28, 546, label, 13, MUTED)]
    e += [text(1250, 546, '独立色阶区分事项', 13, MUTED), rect(330, 580, 1200, 54, '#EAE6EC', 13)]
    def minute(m):
        return 330+(m-480)/960*1200
    for start, end, y, height, fill, done in [(540, 600, 585, 44, '#DED8E4', True), (660, 720, 585, 44, '#E8E1ED', False),
                                             (720, 1080, 585, 44, INK, False), (780, 960, 590, 34, '#9B87AD', False),
                                             (810, 900, 596, 22, '#554B67', False), (1200, 1260, 585, 44, '#BFB5CC', False)]:
        xx=minute(start)+2; ww=minute(end)-minute(start)-4
        e.append(rect(xx, y, ww, height, fill, 8, 'stroke="white" stroke-width="2"'))
        if done: e.append(check(xx+ww/2, y+height/2, MUTED))
        elif start <= 860 < end: e.append(circle(xx+ww-9, y+height/2, 2.5, 'white'))
    e += [rect(minute(810)-1, 593, minute(900)-minute(810)+2, 28, 'none', 11, 'stroke="#332D3D" stroke-width="2"'),
          line(minute(860), 576, minute(860), 639, CORAL, 2), circle(minute(860), 576, 5, CORAL)]
    for hour in range(8, 25, 2):
        e.append(text(minute(hour*60), 661, str(hour), 13, MUTED, extra='text-anchor="middle"'))
    e.append(pill(minute(860)-30, 645, 60, '14:20', CORAL, 'white'))
    # The main illustration leaves the ribbon unobscured; a separate callout
    # below demonstrates the dark hover card and its full event information.
    e += [rect(310, 711, 800, 324, '#FFFDFB', 20, 'fill-opacity=".82" stroke="white"'),
          text(334, 747, '今天的安排', 18, INK, 600), text(960, 747, '完成 1 / 4 段', 13, MUTED)]
    rows = [('13:30–15:00', '研究报告 · 整理材料与提纲', '作业', '1 小时 30 分', False),
            ('15:00–15:30', '站起来走走，喝一杯水', '休息', '30 分钟', False),
            ('20:00–21:00', '线上 Workshop · 设计与创业', 'Workshop', '1 小时', False),
            ('09:00–10:00', '阅读笔记 · 找到三个关键问题', '作业', '1 小时', True)]
    for i, (when, title, category, duration, done) in enumerate(rows):
        yy = 792+i*61
        if i == 0: e.append(rect(324, yy-28, 772, 53, '#EAE5ED', 11))
        e += [text(337, yy+4, when, 13, MUTED), circle(464, yy-2, 10, INK if done else 'white', INK, 1.6)]
        if done:e.append(check(464, yy-2))
        e += [text(488, yy+4, title, 16, '#9A929F' if done else INK, 600 if i == 0 else 400,
                   'text-decoration="line-through"' if done else ''),
              text(1035, yy+4, duration, 12, MUTED, extra='text-anchor="end"'), text(1070, yy+4, '···', 19, MUTED)]
    e += [rect(1130, 711, 420, 182, '#FFFDFB', 20, 'fill-opacity=".82" stroke="white"'),
          text(1152, 747, '接下来的节点', 18, INK, 600),
          pill(1152, 770, 64, '2 天后', '#F6E6E2', '#9E3B2C'), text(1230, 789, '交互原型提交', 17, INK, 600),
          text(1230, 814, '11 月 4 日 · 23:59 · 作业', 13, MUTED),
          pill(1152, 841, 64, '5 天后'), text(1230, 860, '小组 Presentation', 16, INK, 500),
          rect(1130, 913, 420, 122, '#FFFDFB', 20, 'fill-opacity=".82" stroke="white"'),
          text(1152, 950, '长期项目 · 交互设计作品集', 17, INK, 600),
          text(1152, 981, '累计投入 8 小时 · 目标还有 21 天', 14, MUTED),
          rect(1152, 1001, 370, 6, '#EAE4ED', 3), rect(1152, 1001, 128, 6, CORAL, 3),
          text(50, 1112, '看清今天，也看见已经付出的努力。', 24, INK, 600),
          text(1550, 1112, 'INTERFACE ILLUSTRATION · FICTIONAL DATA', 13, MUTED, extra='text-anchor="end"')]
    write('preview.svg', 1600, 1160, '我Due！新版今日工作台',
          '新版工作台示意，使用虚构日程：紫墨与珊瑚品牌、专注控制、每日u杯、独立色阶的重叠时间块、未完成在前的清单、截止节点与长期项目。不是实际截图。', e, defs)


def brand_assets():
    e = [rect(0, 0, 1200, 370, PAPER, 26), text(40, 48, '会说话的 u，也是「我Due！」的提醒。', 25, INK, 650),
         logo(42, 84, 380, 161), line(465, 88, 465, 297),
         rect(508, 98, 156, 156, '#F0EAE3', 36), logo(514, 104, 144, 144, True),
         text(50, 291, '紫墨字标 × 珊瑚嘴形 u × 水滴感叹号', 16, MUTED),
         text(530, 291, '应用标志', 15, MUTED)]
    for x, color, label in [(748, INK, '紫墨'), (883, CORAL, '珊瑚'), (1018, PAPER, '暖底')]:
        e += [rect(x, 113, 94, 94, color, 15, 'stroke="#E4DEE5"'),
              text(x+47, 239, label, 15, INK, 600, 'text-anchor="middle"'),
              text(x+47, 267, color, 13, MUTED, extra='text-anchor="middle"')]
    e += [line(40, 318, 1160, 318), text(40, 349, '矢量字标、透明背景 PNG 与 macOS 图标文件均已包含在开源仓库中。', 15, MUTED)]
    write('brand.svg', 1200, 370, '我Due！品牌标志与配色', '已定稿的嘴形u字标、应用标志和三种品牌颜色，原始矢量与透明PNG可下载。', e)


def hover_detail():
    e=[rect(0, 0, 1200, 280, PAPER, 24), text(38, 46, '重叠，也能一段段看清。', 25, INK, 650),
       text(38, 78, '独立色阶与边界区分事件；移到某一段，上方显示完整信息。', 16, MUTED),
       rect(38, 165, 1124, 56, '#EAE6EC', 13),
       rect(182, 170, 850, 46, INK, 9, 'stroke="white" stroke-width="2"'),
       rect(298, 176, 480, 34, '#9B87AD', 8, 'stroke="white" stroke-width="2"'),
       rect(352, 182, 225, 22, '#554B67', 7, 'stroke="white" stroke-width="2"'),
       rect(349, 179, 231, 28, 'none', 10, 'stroke="#332D3D" stroke-width="2"'),
       rect(325, 94, 474, 60, INK, 12),
       text(342, 117, '13:30–15:00 · 1 小时 30 分钟 · 进行中', 13, '#C9C2D0'),
       text(342, 141, '研究报告 · 整理材料与提纲', 17, 'white', 600),
       line(486, 161, 486, 225, CORAL, 2), circle(486, 161, 5, CORAL),
       '<path d="M471 187l4 19 5-6 8 1Z" fill="white" stroke="#332D3D" stroke-width="1.2" stroke-linejoin="round"/>',
       text(38, 248, '08:00', 13, MUTED), text(1162, 248, '24:00', 13, MUTED, extra='text-anchor="end"')]
    write('ribbon-detail.svg', 1200, 280, '动线重叠事件与悬停信息卡', '独立紫灰色阶和白色边界的重叠方块，上方深色卡片显示虚构事项的时间、时长、状态和标题。界面示意。', e)


if __name__ == '__main__':
    DOCS.mkdir(exist_ok=True)
    brand_header()
    workbench()
    brand_assets()
    hover_detail()
    print('Generated self-contained brand, workbench and hover-detail illustrations with fictional data.')
