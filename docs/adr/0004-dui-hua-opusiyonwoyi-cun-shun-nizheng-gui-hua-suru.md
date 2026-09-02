---
number: 4
title: 対話オプションを依存順に正規化する
status: accepted
date: 2026-09-02
---

# 対話オプションを依存順に正規化する

## Context and Problem Statement

生成機能には、先行する回答によって表示可否や実効値が変わる選択肢がある。対話入力と CLI 入力が別の規則を持ったり、省略値を実行中に推測したりすると、確認内容と実行結果が一致しなくなる。

## Decision Drivers

* 対話と CLI の回答を同じ設定契約で扱う
* 質問の依存関係を循環させない
* 非表示、`Auto`、矛盾する組み合わせを実行前に解決する
* 回答、実効値、実行予定の差を利用者へ示す

## Considered Options

* 各 step が必要な値を実行時に判断する
* 対話と CLI に別々の option 処理を持たせる
* 回答を依存順に収集し、共通の設定と実行計画へ正規化する

## Decision Outcome

質問を有向非巡回な依存順で定義し、CLI の `--OPTION=VALUE` を同じ質問への事前回答として扱う。全適用可能項目の収集後に未回答、無効値、矛盾、`Auto`、非適用値を一度だけ正規化し、不変な configuration と execution plan を構築する。

### Consequences

* Good, because 対話実行と CLI 事前回答で同じ実効値を得られる
* Good, because 非表示項目と派生値の理由を確認画面へ表示できる
* Bad, because 新しい option は質問順序、表示条件、正規化、step への影響を同時に定義する必要がある

### Confirmation

選択肢の正規化、質問順序、部分的 CLI 事前回答、全回答済み時の無対話、矛盾の生成前拒否をテストする。

## More Information

現在の option 一覧と規則は[対話オプションの定義方針](../reference/options.md)を参照する。
