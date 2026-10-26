def lum(h):
    h = h.lstrip('#')
    def ch(v):
        v = v / 255.0
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)

def cr(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)

sets = {
    'dark': dict(band='#202020', active='#323236', inactive='#242426', hover='#2A2A2C', inactive_border='#38383A',
                 separator='#303030', terminal='#282C34', accent='#749CE0', accent_border='#6A96DE',
                 sys_accent='#6872A3', sys_border='#5E6CA1', text_primary='#DCDCE0', text_inactive='#BEBEC2'),
    'light': dict(band='#F3F3F3', active='#FFFFFF', inactive='#F6F6F6', hover='#FAFAFA', inactive_border='#C3C3C3',
                  separator='#D1D1D1', terminal='#282C34', terminal_light='#FFFFFF', accent='#0078D4', accent_border='#0078D4',
                  sys_accent='#6872A3', text_primary='#1B1B1B', text_inactive='#606060'),
}
pairs = [
    ('active', 'band'), ('inactive', 'band'), ('active', 'inactive'), ('active', 'terminal'), ('band', 'terminal'),
    ('inactive', 'terminal'), ('accent', 'band'), ('accent_border', 'band'), ('accent', 'active'), ('sys_accent', 'band'),
    ('sys_border', 'band'), ('inactive_border', 'band'), ('separator', 'band'), ('separator', 'terminal'),
    ('text_primary', 'active'), ('text_inactive', 'inactive'), ('text_primary', 'terminal'), ('text_inactive', 'band'),
    ('terminal_light', 'band'), ('terminal_light', 'inactive'),
]
for name, s in sets.items():
    print('==', name)
    for a, b in pairs:
        if a in s and b in s:
            print('  %-15s %s vs %-15s %s : %.2f:1' % (a, s[a], b, s[b], cr(s[a], s[b])))
