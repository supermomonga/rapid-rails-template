---
number: 1
title: アーキテクチャ上の判断を記録する
status: accepted
date: 2026-09-02
---

# アーキテクチャ上の判断を記録する

## Context and Problem Statement

Rapid Rails Template の設計判断は、現在の構成や手順を説明する文書と同じ場所で更新されてきた。そのままでは、現在の仕様と、なぜその方針を選んだかという履歴を区別しにくい。設計判断の状態、理由、後続判断との関係を検証可能な形で管理する必要がある。

## Decision Drivers

* 現在の仕様と判断時点の理由を分離する
* 判断の状態と関係を一貫した形式で管理する
* リポジトリ内で検索、一覧化、検証できるようにする

## Considered Options

* 通常の設計文書だけで判断理由も管理する
* ADR を手作業で管理する
* `adrs` CLI で NextGen MADR を管理する

## Decision Outcome

`adrs` CLI の NextGen mode と MADR full template を使い、ADR を `docs/adr/` に保存する。現在の構成、選択肢、処理順序は更新可能な参照文書として `docs/reference/` に分離する。

### Consequences

* Good, because 現在の仕様を更新しても判断時点の理由と状態を ADR に残せる
* Good, because `adrs doctor`、検索、一覧、JSON export、TOC 生成を共通の CLI で実行できる
* Bad, because 設計変更時は参照文書だけでなく ADR の lifecycle も確認する必要がある

### Confirmation

`adrs -C . doctor` が成功し、`adrs -C . generate toc` の出力と `docs/adr/README.md` が一致することを確認する。

## More Information

ADR repository の設定は [`adrs.toml`](../../adrs.toml)、現在の構成を説明する文書は [`docs/reference/`](../reference/) を参照する。
