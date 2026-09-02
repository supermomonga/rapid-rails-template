---
number: 11
title: 生成結果を型検査・契約テスト・UI 証跡で検証する
status: accepted
date: 2026-09-02
---

# 生成結果を型検査・契約テスト・UI 証跡で検証する

## Context and Problem Statement

テンプレート自身の単体テストだけでは、生成アプリケーションの型、library generator との統合、画面表示、responsive layout を確認できない。生成した成果物を実際の Rails アプリケーションとして検証し、保存済み UI 証跡の鮮度も判定する必要がある。

## Decision Drivers

* Ruby 本体、Gem、Rails DSL の型不整合を検出する
* option ごとの生成物契約と実行順序を検証する
* 実際の認証・database・browser 経路で画面を確認する
* 証跡と生成元の不一致を fingerprint で検出する

## Considered Options

* テンプレート文字列の単体テストだけを行う
* 生成アプリケーションの自動テストだけを行う
* 型検査、契約テスト、生成アプリテスト、UI 証跡を組み合わせる

## Decision Outcome

生成アプリへ Sorbet、sorbet-runtime、Tapioca を常設し、Gem RBI、Rails DSL RBI、shim、inline signature を検証する。リポジトリでは unit・integration・contract test に加え、全部入り日本語 sample を生成して Rails test、RuboCop、cache smoke、Playwright による desktop・mobile UI 証跡を検証する。証跡の鮮度は関連ソースの fingerprint で判定する。

### Consequences

* Good, because template、生成コード、runtime、画面の異なる失敗を検出できる
* Good, because UI 証跡が現在の生成元と対応していることを検証できる
* Bad, because 全検証には sample 生成、browser、型定義生成の実行時間が必要になる
* Bad, because library 更新時は契約、生成物、証跡を同時に更新する必要がある

### Confirmation

`bin/verify-bootstrap`、Minitest、生成アプリの `bin/ci` と `srb tc`、`rake evidence:verify` が成功し、証跡更新時は対象画像を実際に確認する。

## More Information

現在の検証対象は[アーキテクチャ](../reference/architecture.md)、実行順序は[テンプレート処理フロー](../reference/template-flow.md)、技術詳細は[採用技術とセットアップ要件](../reference/stack.md)を参照する。
