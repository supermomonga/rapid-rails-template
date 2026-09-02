---
number: 9
title: Solid 系コンポーネントと運用画面を必要な構成だけに導入する
status: accepted
date: 2026-09-02
---

# Solid 系コンポーネントと運用画面を必要な構成だけに導入する

## Context and Problem Statement

Rails 8.1 は Solid Cache、Solid Queue、Solid Cable をまとめて生成するが、本プロジェクトでは Queue と Cable が選択機能である。ジョブ監視と運用 task も役割が異なり、不要な構成へ database、process、管理画面を残さない必要がある。

## Decision Drivers

* 選択されていない component の artifact を生成しない
* Web Push と運用 task が必要とする Active Job を明示する
* ジョブ監視と運用 task の責務を分離する
* 管理画面を既存の admin 認証・認可へ統合する

## Considered Options

* Rails 8.1 の Solid 系既定値をそのまま使う
* `--skip-solid` の後に必要な component だけを公式 generator で導入する
* 別の queue・cache・cable adapter を fallback として使う

## Decision Outcome

`rails new` では `--skip-solid` を指定し、選択済みの Solid Cache、Solid Queue、Solid Cable だけを公式 install generator で導入する。Mission Control Jobs は queue と job の監視・retry・discard、Maintenance Tasks は運用 task の開始・進捗管理を担当し、独立した route と policy で既存 admin 領域へ統合する。

### Consequences

* Good, because 不要な database、Gem、process、画面を生成しない
* Good, because 管理機能が既存の Devise と Action Policy を再利用する
* Bad, because option 間の依存と artifact の有無を構成別に検証する必要がある
* Bad, because Rails の一括生成を使わず component ごとの導入順序を管理する必要がある

### Confirmation

Solid Queue の有無、Web Push による必須化、Mission Control Jobs と Maintenance Tasks の独立した route・policy・画面、無効構成での artifact 不在をテストする。

## More Information

現在の option と各 component の構成は[対話オプションの定義方針](../reference/options.md)と[採用技術とセットアップ要件](../reference/stack.md)を参照する。
