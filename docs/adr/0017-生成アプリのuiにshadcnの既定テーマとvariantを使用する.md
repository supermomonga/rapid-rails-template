---
number: 17
title: 生成アプリのUIにshadcnの既定テーマとvariantを使用する
status: accepted
date: 2026-09-25
links:
- target: 16
  kind: amends
---

# 生成アプリのUIにshadcnの既定テーマとvariantを使用する

## Context and Problem Statement

ADR 16の移行実装には旧デザインを保持するための色・文字組みのCSS、Card余白の一律上書き、状態別の独自色が残った。これらはgemのコンポーネントを既定の見た目で使うという新しい要件と合わず、gem更新時の差分も増やす。

## Decision Drivers

* `shadcn_view_components` 0.2.0の色とコンポーネントの見た目を既定値で使う
* 状態や操作の意味を公開variantと本文・ARIAで伝える
* ページ移動と同一画面内のパネル切替の操作契約を守る

## Considered Options

* 旧配色と余白を独自CSSとutilityで維持する
* gemの既定テーマと公開variantを使用し、配置に必要なutilityだけ残す

## Decision Outcome

gemの既定テーマと公開variantを使用する。生成アプリではsemantic tokenを再定義せず、本文全体の文字組みも上書きしない。Card::Contentの既定余白を維持し、表を端まで表示するなど構造上必要な箇所だけ個別に調整する。Alertは通常とdestructive、ButtonやBadgeは用途に応じた公開variantを使う。route linkはNavigationMenu、同一画面に複数のpanelを置いて切り替える操作はTabsを使う。Tabs::Listの`default`と`line`は周囲の表示面に合わせて選ぶ。

### Consequences

* Good, because gemの更新に伴う独自CSSの追随が減る
* Good, because コンポーネントのvariantと見た目が一致する
* Bad, because 旧`DESIGN.md`の配色と画面の余白は変わり、画像証跡を撮り直す必要がある

### Confirmation

生成元と生成アプリのTailwind入力に独自の色・基本文字組みの上書きがないこと、Card等の公開classとvariantを使用していることを確認する。最小構成と全部入り構成のテスト、desktop・mobileの撮影と目視確認を行う。

## More Information

ADR 16の「DESIGN.mdの色と文字組みを保持する」部分を変更する。gem 0.2.0同梱のCSS、generated contracts、Stimulus Tabs controllerを確認した。gemの既定テーマやvariant契約が変わった場合は、生成アプリの表示と操作を再検証する。
