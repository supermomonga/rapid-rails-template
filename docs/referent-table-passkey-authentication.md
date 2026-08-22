| 出典 | 目的 | 具体対象 | 役割 | 前後関係 | 候補語 | 初出定義 |
|---|---|---|---|---|---|---|
| 承認済み計画 | パスワードなしでUserを認証する | Userに属し、WebAuthn assertionまたはSIWE署名を検証できるPasskey credentialとEVM wallet identity | 記録 | 登録 → ログイン → 追加・解除 | 認証資格情報 | 認証資格情報とは、ログインに使用できるPasskey credentialまたはSIWE identityを指す。 |
| 承認済み計画 | 唯一の端末喪失によるロックアウトを注意喚起する | 全認証資格情報が未バックアップのPasskey 1件だけであるUserの状態 | 状態 | ログイン成功 → 資格情報数とBSを評価 → warning flash | 高リスク状態 | 高リスク状態とは、全認証資格情報が1件だけで、その1件がbackup state falseのPasskeyである状態を指す。 |
| WebAuthn | 登録・認証要求の使い回しと別sessionでの利用を防ぐ | purpose、User、session、期限、消費時刻、必要時は削除対象へ結び付ける一回限りのserver-side記録 | 記録 | challenge発行 → credential生成・assertion → 検証 → 原子的消費 | WebAuthn challenge | WebAuthn challengeとは、1回のWebAuthn ceremonyをserver側の文脈へ結び付ける期限付き記録を指す。 |
| 承認済み計画 | 削除後に残るログイン手段が現在利用可能であることを確認する | 削除対象を候補から除外し、別のPasskeyまたはSIWE identityで同じ削除操作を承認する検証 | 手段 | 削除対象選択 → 対象外資格情報で検証 → lock下で再確認 → 削除 | 対象外再認証 | 対象外再認証とは、削除対象ではない認証資格情報によって対象を削除してよいことを操作ごとに証明する手段を指す。 |
| 承認済み計画 | 登録とログインの意味を混同しない | 未登録credential/addressだけがUserを作成し、ログインでは既存Userだけを認証する独立した処理 | 事象 | 新規登録ceremonyまたはログインceremony → 検証 → User作成またはsign in | 認証ceremony | 認証ceremonyとは、signup、login、link、対象外再認証の目的ごとに分離したWebAuthnまたはSIWEの検証処理を指す。 |
| 承認済み計画 | Passkey登録時に識別しやすい初期名を入力なしで付ける | 検証済みcredentialのAAGUIDと登録requestのUser-Agentから決定し、後から編集できる表示専用の名前 | 値 | credential検証 → 既知AAGUID名または登録OS名を決定 → credential保存 → 必要ならedit | Passkey初期名 | Passkey初期名とは、認証判断には使わず、同名を許可するPasskey credentialの化粧的な登録時表示名を指す。 |
