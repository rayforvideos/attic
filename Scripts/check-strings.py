#!/usr/bin/env python3
"""번역의 자리표시자가 키와 어긋나면 String(format:)이 잘못된 타입을 읽어
SIGSEGV로 앱이 죽는다(실측 2026-08-06). 어순을 바꿔야 하면 %1$@ 같은 위치
지정을 쓴다. 빌드 전에 이 검사를 통과해야 한다."""
import re, subprocess, plistlib, sys, glob

def specs(s):
    s = s.replace('%%', '')
    return re.findall(r'%(?:(\d+)\$)?(@|lld|ld|d|f|lf)', s)

fail = 0

# 코드에 있는데 번역이 없는 문구를 찾는다. UI 문구가 L()·Text()로 감싸이지
# 않으면 영어 환경에서 한국어가 그대로 나온다(실측으로 여러 번 겪었다).
def untranslated(table):
    known_exceptions = {
        "스크린샷 ",              # macOS가 붙이는 파일명 접두사 — 번역 대상 아님
        "kill(0)/kill(-1) 방어",  # precondition 메시지
        "한국어",                  # 언어 이름은 그 언어로 적는다
    }
    found = []
    for path in glob.glob('Sources/**/*.swift', recursive=True):
        for i, line in enumerate(open(path), 1):
            stripped = line.strip()
            if stripped.startswith(('//', '///', '*')): continue
            if 'logger.' in line or 'privacy:' in line: continue
            code = re.sub(r'\s//.*$', '', line)
            for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', code):
                value = m.group(1)
                if not re.search(r'[가-힣]', value): continue
                if value in table or value in known_exceptions: continue
                found.append(f"{path}:{i}  {value[:60]}")
    return found

for path in glob.glob('Resources/*.lproj/Localizable.strings'):
    out = subprocess.run(['plutil', '-convert', 'xml1', '-o', '-', path],
                         capture_output=True)
    if out.returncode != 0:
        print(f"FAIL {path}: 형식 오류\n{out.stderr.decode()}")
        fail += 1
        continue
    table = plistlib.loads(out.stdout) if out.stdout.strip() else {}
    for key, value in table.items():
        ks, vs = specs(key), specs(value)
        # 위치 지정을 쓰면 순서가 달라도 되지만, 타입 집합은 같아야 한다
        if any(i for i, _ in vs):
            if sorted(t for _, t in ks) != sorted(t for _, t in vs):
                print(f"FAIL {path}: 자리표시자 타입이 다름\n  키: {key}\n  값: {value}")
                fail += 1
        elif [t for _, t in ks] != [t for _, t in vs]:
            print(f"FAIL {path}: 자리표시자 순서/개수가 다름 (위치 지정 %1$@ 을 쓰세요)"
                  f"\n  키: {key}\n  값: {value}")
            fail += 1

# stringsdict도 같은 이유로 검사한다. 각 변형(one/other)을 포맷 문자열에
# 끼워 넣은 결과의 자리표시자가 키와 어긋나면 런타임에 똑같이 죽는다.
for path in glob.glob('Resources/*.lproj/Localizable.stringsdict'):
    with open(path, 'rb') as f:
        table = plistlib.load(f)
    for key, entry in table.items():
        fmt = entry.get('NSStringLocalizedFormatKey', '')
        variables = {name: cfg for name, cfg in entry.items()
                     if isinstance(cfg, dict)}
        names = re.findall(r'%#@(\w+)@', fmt)
        if set(names) != set(variables):
            print(f"FAIL {path}: 포맷의 변수와 정의가 다름\n  키: {key}")
            fail += 1
            continue
        # 변수 하나씩 각 변형으로 바꿔보고, 나머지는 other로 채운다
        for name, cfg in variables.items():
            variants = {k: v for k, v in cfg.items()
                        if k not in ('NSStringFormatSpecTypeKey',
                                     'NSStringFormatValueTypeKey')}
            for label, variant in variants.items():
                resolved = fmt
                for other in names:
                    text = variant if other == name else variables[other]['other']
                    resolved = resolved.replace(f'%#@{other}@', text)
                ks, rs = specs(key), specs(resolved)
                # .strings 검사와 같은 규칙: 위치 지정(%1$@)을 쓰면 순서가
                # 달라도 되고, 타입 집합만 같으면 된다
                if any(i for i, _ in rs):
                    mismatch = sorted(t for _, t in ks) != sorted(t for _, t in rs)
                else:
                    mismatch = [t for _, t in ks] != [t for _, t in rs]
                if mismatch:
                    print(f"FAIL {path}: 자리표시자가 키와 다름 ({name}.{label})"
                          f"\n  키: {key}\n  값: {resolved}")
                    fail += 1

# en 테이블 기준으로 누락을 검사한다
en = subprocess.run(['plutil', '-convert', 'xml1', '-o', '-',
                     'Resources/en.lproj/Localizable.strings'], capture_output=True)
en_table = plistlib.loads(en.stdout) if en.returncode == 0 and en.stdout.strip() else {}
for line in untranslated(en_table):
    print(f"FAIL 번역 없음: {line}")
    fail += 1

print("번역 검사: " + ("통과" if fail == 0 else f"{fail}건 실패"))
sys.exit(1 if fail else 0)
