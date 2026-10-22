"""Summarize warmed navigation frames; retains UI and raster budgets separately."""
import json
from pathlib import Path
import sys


def percentile(values, fraction):
    values = sorted(values)
    index = (len(values) - 1) * fraction
    low = int(index)
    high = min(low + 1, len(values) - 1)
    return values[low] + (values[high] - values[low]) * (index - low)


root = Path(sys.argv[1])
rows = []
for candidate in ['before', 'native500', '280-240', '300-260', '320-280']:
    data = json.loads((root / candidate / 'frames.json').read_text())
    timeline = json.loads((root / candidate / 'timeline.json').read_text())
    assert data['mode'] == 'profile'
    assert data['run_id'] == timeline['run_id'], 'Mismatched frame and timeline runs'
    for style in ['plain', 'blur', 'glass']:
        intervals = [i for i in data['intervals'] if i['style'] == style]
        assert len(intervals) == 20, (candidate, style, len(intervals))
        frames = [
            frame for frame in data['frames']
            if any(i['start_us'] <= frame['vsync_us'] < i['end_us'] for i in intervals)
        ]
        assert len(frames) > 25, (candidate, style, 'Check timeline clock alignment')
        row = {'candidate': candidate, 'style': style, 'frames': len(frames)}
        for metric in ['ui_us', 'raster_us']:
            values = [frame[metric] / 1000 for frame in frames]
            prefix = metric.removesuffix('_us')
            row.update({
                prefix + '_p50_ms': round(percentile(values, .5), 3),
                prefix + '_p95_ms': round(percentile(values, .95), 3),
                prefix + '_max_ms': round(max(values), 3),
            })
        for budget in [16.67, 8.33]:
            row[f'either_over_{budget}_ms'] = sum(
                max(frame['ui_us'], frame['raster_us']) > budget * 1000
                for frame in frames
            )
        rows.append(row)
(root / 'summary.json').write_text(json.dumps(rows, indent=2) + '\n')
print('| Candidate | Style | Frames | UI p95/max ms | Raster p95/max ms | >16.67 / >8.33 ms |')
print('| --- | --- | ---: | ---: | ---: | ---: |')
for row in rows:
    print(f"| {row['candidate']} | {row['style']} | {row['frames']} | "
          f"{row['ui_p95_ms']}/{row['ui_max_ms']} | "
          f"{row['raster_p95_ms']}/{row['raster_max_ms']} | "
          f"{row['either_over_16.67_ms']}/{row['either_over_8.33_ms']} |")
