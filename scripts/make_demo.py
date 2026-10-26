#!/usr/bin/env python3
"""Generate fictional plans. Refuse to replace an existing document."""
import argparse
import json
import uuid
from datetime import datetime, timedelta
from pathlib import Path


def document():
    now = datetime.now().replace(second=0, microsecond=0)
    tasks = []

    def task(title, when, kind, category, timed=True, **extra):
        item = dict(id=str(uuid.uuid4()), title=title, day=when.strftime('%Y-%m-%d'),
                    completed=False, createdAt=0, kind=kind, categoryID=category)
        if timed:
            item['startMinute'] = when.hour * 60 + when.minute
        item.update(extra)
        tasks.append(item)
        return item

    prototype = task('提交交互原型', now + timedelta(minutes=22), '提交 / 截止', 'assignment', importance=3, estimatedMinutes=120)
    task('Presentation 幻灯片定稿', now + timedelta(hours=5), '提交 / 截止', 'presentation', importance=2)
    report = task('小组研究报告', now + timedelta(hours=48), '提交 / 截止', 'assignment', estimatedMinutes=180)
    task('报名周末展览', now, '提交 / 截止', 'exhibition', timed=False)
    task('线上设计 Workshop', now.replace(hour=10, minute=0), '活动 / 行程', 'workshop',
         endMinute=660, link='https://example.org/workshop', notes='虚构演示活动；链接不会连接真实会议。')
    task('三日旅行', now + timedelta(days=7), '活动 / 行程', 'travel', timed=False,
         endDay=(now + timedelta(days=9)).strftime('%Y-%m-%d'))
    blocks = []
    for title, start, end, category, linked, rest in [
        ('起床、早餐与走动', 600, 630, 'home', None, False),
        ('写项目草稿', 660, 720, 'assignment', report['id'], False),
        ('午饭与休息', 720, 780, 'rest', None, True),
        ('制作交互原型', 780, 900, 'assignment', prototype['id'], False),
        ('站起来，喝点水', 900, 915, 'rest', None, True),
        ('整理演讲素材', 915, 1020, 'presentation', None, False),
    ]:
        blocks.append(dict(id=str(uuid.uuid4()), title=title, day=now.strftime('%Y-%m-%d'),
                           startMinute=start, endMinute=end, categoryID=category,
                           taskID=linked, rest=rest, completed=False, createdAt=0))
    return dict(version=2, tasks=tasks, timeBlocks=blocks)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Output exists. Choose a new path to preserve existing demo edits.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document(), ensure_ascii=False, indent=2) + '\n')
    print('Fictional demo data created.')
