---
number: 2
title: bootstrap.rb を決定的な単一配布物として生成する
status: accepted
date: 2026-09-02
---

# bootstrap.rb を決定的な単一配布物として生成する

## Context and Problem Statement

利用者が取得して直接実行できる単一ファイルと、保守しやすい責務別ソースを両立する必要がある。配布ファイルを直接保守すると、ランチャーと Application Template payload の境界が不明瞭になり、分割ソースとの不一致も検出できない。

## Decision Drivers

* 配布時の取得と実行を単純にする
* 責務別のソース構成を維持する
* 配布物と正本の不一致を自動検出する
* 可変 branch ではなく再現可能な内容を配布する

## Considered Options

* 単一の `bootstrap.rb` を直接編集する
* 分割ソースだけを配布する
* 分割ソースから単一の `bootstrap.rb` を決定的に生成する

## Decision Outcome

`src/rapid_rails_template/` を保守対象の正本とし、前段ランチャーと Application Template payload を含むルートの `bootstrap.rb` を決定的に生成してコミットする。正式な配布 URL は release tag または commit に固定する。

### Consequences

* Good, because 利用者は単一ファイルを取得して実行できる
* Good, because 実装は責務別ファイルに分割でき、`bin/verify-bootstrap` で同期を検証できる
* Bad, because 分割ソースを変更するたびに配布物の再生成が必要になる

### Confirmation

`bin/build-bootstrap` が決定的に生成し、`bin/verify-bootstrap` が同期済みの状態で成功することを確認する。

## More Information

現在の構成は[アーキテクチャ](../reference/architecture.md)、実行順序は[テンプレート処理フロー](../reference/template-flow.md)を参照する。
