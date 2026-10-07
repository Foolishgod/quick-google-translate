"""Preserve published update entries when Sparkle regenerates a versioned feed."""
import copy
from pathlib import Path
import xml.etree.ElementTree as ET

NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'


def preserve_history(tree, previous_feed, current_build):
    previous_feed = Path(previous_feed)
    if not previous_feed.stat().st_size:
        return
    historical = {
        item.findtext(f'{{{NS}}}version'): item
        for item in ET.parse(previous_feed).findall('./channel/item')
        if item.findtext(f'{{{NS}}}version') != current_build
    }
    channel = tree.find('channel')
    # Respect Sparkle's pruning; restore only history still present in the generated feed.
    for index, item in enumerate(list(channel)):
        build = item.findtext(f'{{{NS}}}version')
        if item.tag == 'item' and build in historical:
            channel.remove(item)
            channel.insert(index, copy.deepcopy(historical[build]))
