#!/usr/bin/env python3
"""index.html에서 영어 페이지(en.html)를 만들어낸다.

왜 두 파일이 필요한가: 링크 미리보기(OG 태그)는 크롤러가 HTML만 읽어서 판단한다.
자바스크립트도 안 돌리고 브라우저 언어도 안 본다. 그래서 한 주소로는 언어별 카드를
줄 수 없다. 주소를 나누는 것이 유일한 방법이다.

손으로 두 벌을 관리하면 반드시 어긋나므로, 한국어 페이지 하나만 고치고 이 스크립트로
영어 페이지를 다시 만든다.

    python3 build-en.py
"""
import pathlib
import sys

SITE = "https://rayforvideos.github.io/attic"

REPLACEMENTS = [
    # 문서 언어. CSS가 이 값으로 한국어/영어 문구를 가른다.
    ('<html lang="ko">', '<html lang="en">'),

    ('<title>Attic — 쓰지 않는데 자리만 차지하는 파일을 찾아드려요</title>',
     '<title>Attic — Find the files you stopped using but never deleted</title>'),

    ('<meta name="description" content="맥에 숨어 있는 캐시와 오래된 파일을 찾아주는 메뉴바 앱. '
     '고른 것만 휴지통으로 옮기고, 앱이 알아서 지우지 않습니다.">',
     '<meta name="description" content="A menu bar app that finds hidden caches and stale files on '
     'your Mac. Only what you pick goes to the Trash, and nothing is deleted on its own.">'),

    ('<meta property="og:description" content="쓰지 않는데 자리만 차지하는 파일을 찾아드려요">',
     '<meta property="og:description" content="Find the files you stopped using but never deleted">'),

    (f'<meta property="og:image" content="{SITE}/og.png">',
     f'<meta property="og:image" content="{SITE}/og-en.png">'),

    (f'<meta property="og:url" content="{SITE}/">',
     f'<meta property="og:url" content="{SITE}/en.html">'),

    ('<meta property="og:image:alt" content="Attic — 쓰지 않는데 자리만 차지하는 파일을 찾아드려요">',
     '<meta property="og:image:alt" content="Attic — Find the files you stopped using but never deleted">'),

    # 기본 언어. 이 페이지는 영어로 공유되는 주소이므로 영어로 연다.
    # 사용자가 직접 고른 값(localStorage)은 그대로 존중한다.
    ('setLang(savedLang || (prefersKorean ? "ko" : "en"));',
     'setLang(savedLang || "en");'),
]


def main() -> int:
    here = pathlib.Path(__file__).parent
    source = here / "index.html"
    html = source.read_text()

    for old, new in REPLACEMENTS:
        if old not in html:
            print(f"찾지 못했습니다: {old[:70]}...", file=sys.stderr)
            print("index.html이 바뀌었으면 이 스크립트도 같이 고쳐야 합니다.", file=sys.stderr)
            return 1
        html = html.replace(old, new)

    # 검색엔진에 서로가 같은 페이지의 다른 언어판임을 알린다.
    # index.html에 이미 들어 있으면 그대로 둔다 — 두 번 넣으면 중복 태그가 된다.
    if "hreflang" not in html:
        html = html.replace('<meta name="theme-color"',
                            f'<link rel="alternate" hreflang="ko" href="{SITE}/">\n'
                            f'<link rel="alternate" hreflang="en" href="{SITE}/en.html">\n'
                            '<meta name="theme-color"')

    html = html.replace("<head>", "<head>\n<!-- build-en.py가 index.html에서 만든 파일입니다. 직접 고치지 마세요. -->")

    (here / "en.html").write_text(html)
    print("en.html을 다시 만들었습니다")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
