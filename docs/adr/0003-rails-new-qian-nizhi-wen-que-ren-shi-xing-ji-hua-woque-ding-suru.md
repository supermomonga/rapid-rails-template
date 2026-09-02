---
number: 3
title: rails new 前に質問・確認・実行計画を確定する
status: accepted
date: 2026-09-02
---

# rails new 前に質問・確認・実行計画を確定する

## Context and Problem Statement

Rails Application Template だけでは、利用者へ質問できる時点ですでに Rails 標準ファイルが生成されている。生成前に必要な generator option もあるため、キャンセル時の無変更と、承認した計画どおりの生成を Application Template 内の後処理だけでは保証できない。

## Decision Drivers

* 最終承認前は生成先と一時ファイルを変更しない
* `rails new` に必要な option を起動前に確定する
* 承認後の追加質問や実行計画の再解釈を禁止する
* 失敗時に別の処理へ暗黙に切り替えない

## Considered Options

* `rails new APP_PATH -m TEMPLATE_URL` で Application Template を直接実行する
* 生成後に不要ファイルを削除して選択結果へ合わせる
* 前段ランチャーで質問、確認、実行を分離する

## Decision Outcome

`bootstrap.rb` が環境検証、全質問、正規化、実行計画の表示、最終確認を `rails new` より前に行う。承認後だけ権限制限された Application Template payload と設定 JSON を一時作成し、確定済み option で `rails new` を起動する。Application Template は再質問しない。

### Consequences

* Good, because キャンセル時に生成先と一時ファイルを残さない
* Good, because generator option と後続 step を同じ承認済み計画から実行できる
* Bad, because Rails Application Template の前に独立したランチャーが必要になる
* Bad, because 承認後に追加情報が必要になった場合は仕様漏れとして失敗する

### Confirmation

キャンセル時の無変更、承認後の無対話、引数分離、一時ファイルの権限と後始末を単体・結合テストで検証する。

## More Information

詳細なフェーズは[テンプレート処理フロー](../reference/template-flow.md)、責務境界は[アーキテクチャ](../reference/architecture.md)を参照する。
