import json


def render(name, obj):
    if obj is None:
        return ""
    if name == "raw":
        return json.dumps(obj, indent=2, sort_keys=True)
    raise NotImplementedError(name)
