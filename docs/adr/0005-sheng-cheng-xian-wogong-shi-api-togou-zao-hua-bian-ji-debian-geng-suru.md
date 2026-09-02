---
number: 5
title: 生成先を公式 API と構造化編集で変更する
status: accepted
date: 2026-09-02
---

# 生成先を公式 API と構造化編集で変更する

## Context and Problem Statement

Application Template は Rails や導入ライブラリが生成したファイルを変更する。曖昧な文字列置換は、対象バージョンで構造が変わったときに誤った位置を変更したり、失敗を見逃したりする可能性がある。

## Decision Drivers

* 対象ツールが提供する契約を優先する
* 変更対象の構造を確認してから編集する
* 想定した構造がない場合は明示的に失敗する
* 対象外バージョン向けの推測的な互換処理を避ける

## Considered Options

* grep と文字列置換でファイルを変更する
* すべての生成物を独自 template で置き換える
* 公式 API、構造化データ操作、AST 編集を優先順位どおり使う

## Decision Outcome

変更手段は、Rails Generator/Application Template API と `Thor::Actions`、ライブラリの公式 API・generator、形式別の構造化データ操作、Prism による Ruby AST 編集の順で選ぶ。安全な構造化手段がない場合は処理を実装せず失敗させる。

### Consequences

* Good, because 対象ツールの公開契約に沿った変更になる
* Good, because Ruby 編集は期待する AST と位置を検証できる
* Bad, because 対象ごとの editor や構造検証が必要になる
* Bad, because 対応していない構造を便宜的な置換で通せない

### Confirmation

各 editor の正常系と期待構造がない場合の失敗を単体テストし、生成アプリケーションの結合テストで変更結果を検証する。

## More Information

現在の優先順位と責務は[アーキテクチャ](../reference/architecture.md)を参照する。
