---
number: 6
title: 生成アプリの基盤技術と対応バージョンを固定する
status: accepted
date: 2026-09-02
---

# 生成アプリの基盤技術と対応バージョンを固定する

## Context and Problem Statement

多数の Rails 構成や互換分岐を扱うと、生成結果と検証組み合わせが増え、テンプレートの再現性が下がる。生成アプリの基盤と対象バージョンを限定し、選択機能が同じ前提の上で動作するようにする必要がある。

## Decision Drivers

* 対象 Rails・Ruby の生成結果を具体的に検証する
* JavaScript bundler を前提としない Rails 標準構成を維持する
* UI、認可、I18n、テストの共通基盤を全構成で揃える
* 対象外バージョン向け互換分岐を持たない

## Considered Options

* 複数世代の Rails・Ruby と複数の frontend 構成へ対応する
* Rails 8.1 と Ruby 4.0 の標準構成を基礎に技術を固定する

## Decision Outcome

対応範囲を Rails `>= 8.1, < 8.2`、Ruby `>= 4.0, < 4.1` に限定する。SQLite、Puma、Propshaft、Importmap、Hotwire、Tailwind CSS 4、daisyUI 5、Minitest を共通基盤とし、Application Identity と ja/en の I18n、Action Policy、Action Text、Active Storage などの常設構成を同じ前提で生成する。

### Consequences

* Good, because 対象バージョンと技術の組み合わせを一貫して検証できる
* Good, because 生成アプリ間で UI と application contract を共有できる
* Bad, because 対象範囲外の Rails・Ruby や別 frontend stack は利用できない
* Bad, because 固定した依存を更新するときは生成物、テスト、参照文書を同時に更新する必要がある

### Confirmation

ランチャーの環境検証、固定 generator option、生成 Gem・設定・asset、全部入りと最小構成の生成テストで確認する。

## More Information

現在の固定技術と setup 要件は[採用技術とセットアップ要件](../reference/stack.md)を参照する。
