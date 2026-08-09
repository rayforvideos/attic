<div align="center">

<img src="https://rayforvideos.github.io/attic/icon.png" width="120" alt="Attic">

# Attic

**쓰지 않는데 자리만 차지하는 파일을 찾아드려요.**

Xcode 빌드 산출물, 기기 지원 파일, 손 뗀 프로젝트의 `node_modules`, 패키지 매니저 캐시.
개발하면서 쌓인 것이 특히 많이 나옵니다. 앱 캐시와 받아두고 잊은 다운로드도 함께 찾습니다.
고른 것만 휴지통으로 옮기고, 앱이 알아서 지우지 않습니다.

[![최신 버전](https://img.shields.io/github/v/release/rayforvideos/attic?label=%EC%B5%9C%EC%8B%A0&color=7fb2e5&style=flat-square)](https://github.com/rayforvideos/attic/releases/latest)
[![다운로드](https://img.shields.io/github/downloads/rayforvideos/attic/total?label=%EB%8B%A4%EC%9A%B4%EB%A1%9C%EB%93%9C&color=7fb2e5&style=flat-square)](https://github.com/rayforvideos/attic/releases)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-1b2027?style=flat-square)](https://github.com/rayforvideos/attic/releases/latest)
[![MIT](https://img.shields.io/badge/license-MIT-1b2027?style=flat-square)](LICENSE)

**[웹사이트](https://rayforvideos.github.io/attic/)** · **[다운로드](https://github.com/rayforvideos/attic/releases/latest)** · **[English](README.md)**

<img src="https://rayforvideos.github.io/attic/screenshot.png" width="400" alt="Attic 화면">

</div>

## 무엇을 찾나

| 종류 | 내용 |
|---|---|
| **앱이 만든 캐시** | 브라우저 기반 앱이 쌓아둔 웹 캐시, 앱마다 만드는 임시 파일 |
| **오래된 빌드 산출물** | Xcode 빌드 결과, 기기 지원 파일, 패키지 매니저 캐시, 안 쓰는 `node_modules` |
| **받아두고 잊은 다운로드** | 설치하고 남은 파일, 오래된 스크린샷, 큰 파일 |
| **지난 배포용 보관본** | 오래된 `.xcarchive` |
| **숨어서 도는 것들** | 로그인·부팅할 때 함께 올라오는 프로그램, 지워진 앱이 남긴 자동 실행 등록 |

캐시처럼 다시 만들어지는 것과, 지우면 끝인 사용자 파일을 나눠서 보여줍니다.
되돌릴 수 없는 것은 「캐시 모두 선택」에 들어가지 않고, 어느 폴더에 있는지 함께 표시합니다.

## 지키는 것

디스크를 맡기는 앱이라, 무엇을 하지 않는지가 먼저입니다.

**고른 것만 휴지통으로 옮깁니다.** 앱이 알아서 지우는 일은 없습니다.

**숫자를 지어내지 않습니다.** 크기를 재지 못한 항목은 목록에서 빼고 그 사실을 알립니다.
끝까지 훑지 못한 폴더가 있으면 "비울 게 없어요"라고 말하지 않습니다.

**옮기기 직전에 다시 잽니다.** 스캔한 값은 오래됐을 수 있습니다. 실제로 비는 용량은 그 순간에
다시 잰 숫자입니다.

**되돌릴 수 없는 것은 그렇다고 말합니다.** 캐시는 다시 만들어지지만 받은 사진은 아닙니다.
아는 만큼만 말합니다.

**허용 목록으로만 움직입니다.** 손댈 수 있는 위치를 미리 정해두고, 그 밖은 전부 거부합니다.
실행 직전에 한 번 더 검증합니다.

## 설치

**[최신 버전 받기](https://github.com/rayforvideos/attic/releases/latest)**

DMG를 열고 Attic을 응용 프로그램 폴더로 끌어다 놓으세요. 실행하면 메뉴바에 디스크 아이콘이
생깁니다. Apple 공증을 받았으므로 경고 없이 열립니다.

Homebrew로 설치할 수도 있습니다:

```sh
brew install rayforvideos/tap/attic
```

macOS 15 세쿼이아 이상이 필요합니다.

## 권한과 통신

**전체 디스크 접근.** 캐시를 찾으려면 다른 앱의 폴더를 봐야 하는데, macOS는 그것을 앱마다 따로
묻습니다. 앱 안의 안내에서 한 번 허용하면 그 뒤로는 묻지 않습니다.

**네트워크는 새 버전 확인에만.** 최신 버전 번호만 읽고, 무엇을 찾았는지나 누구인지는 보내지
않습니다. 설정에서 끌 수 있습니다.

## 업데이트

앱 안에서 받아 교체합니다. 교체 전에 내려받은 앱이 같은 개발자 서명인지와 공증을 통과했는지
확인하고, 하나라도 아니면 설치하지 않습니다. 옛 버전은 지우지 않고 휴지통으로 보냅니다.

## 기여

PR을 환영합니다. `swift test`만 통과하면 되고, 앱을 직접 빌드하거나 서명할 필요는 없습니다.
로직은 전부 `AtticCore`에 있어서 테스트로 확인됩니다.

디스크를 지우는 앱이라 지켜야 하는 규칙이 몇 가지 있습니다.
[CONTRIBUTING.md](CONTRIBUTING.md)를 먼저 읽어주세요.

## 라이선스

[MIT](LICENSE). 개인이든 회사든 자유롭게 쓰고, 고치고, 배포하고, 팔아도 됩니다.
저작권 표시만 남겨주세요.

Copyright (c) 2026 Sangjun Park
