# Persistent Speaker Profiles

## 結論

chronixd-captureの話者IDをセッションをまたいで安定させるため、FluidAudio Sortformerによる話者区間と、WeSpeakerによる話者プロフィールを分離する。

Sortformerは引き続き「誰がいつ話したか」を判定する。
確定済みの単独話者区間からWeSpeakerの256次元embeddingを抽出し、永続的な話者プロフィールと比較する。
人がセッション内の匿名話者をプロフィールへ割り当てる操作を用意し、その結果を正解データとしてプロフィールへ反映する。

embeddingとマッピングは追記形式で保存する。
プロフィールは保存済みデータから再構築する派生データとし、誤った割り当てを後から訂正できるようにする。

## 背景

現在の`speakerId`は`{sessionId}_{speakerIndex}`形式であり、同じセッション内でのみ意味を持つ。
プロセス再起動後の`session_2`が、前回の`session_0`と同じ人物かは判定できない。

既存研究では、少人数の共有端末で話者識別を継続的に改善する場合、音声モデル全体を再学習するのではなく、固定したembedding抽出モデルと、話者ごとに更新するプロフィールを組み合わせる。
話者プロフィールは複数のembeddingまたはその平均値で表し、新しい発言が十分に似ている場合だけ更新する。

参考資料:

- [Baselines and Protocols for Household Speaker Recognition](https://www.isca-archive.org/odyssey_2022/sholokhov22_odyssey.html)
- [FluidAudio Speaker Diarization Guide](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md)
- [FluidAudio API Reference](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md)
- [Version Control of Speaker Recognition Systems](https://research.google/pubs/version-control-of-speaker-recognition-systems/)

## 要件

- Sortformerが返すすべての確定済み区間を`speaker_span`として保存する。
- 3秒以上の単独話者区間から、最大10秒の音声を使ってWeSpeaker embeddingを抽出する。
- 同じ話者についてembeddingを取りすぎないよう、候補作成を一定間隔に制限する。
- embedding、抽出元区間、モデルバージョン、照合結果を追記形式で保存する。
- セッション内の匿名話者を永続プロフィールへ手動で割り当てられるようにする。
- `context`出力時に手動割り当てを解決し、`profileId`を追加する。
- 手動割り当てがない場合は、十分に確かな自動照合結果を使う。
- 手動割り当てを最優先し、自動照合結果は後から上書きできるようにする。
- embedding抽出またはプロフィール照合に失敗しても、ASRとSortformerによる記録は継続する。
- Sortformerの暫定区間を重なり判定に使い、未確定の別話者が重なる音声もembedding候補から外す。
- 通常の`context`出力へ診断用レコードを混ぜず、必要なときだけ明示的に出力する。

## 対象外

- FluidAudioまたはWeSpeakerモデル本体の追加学習
- 文字起こし内容だけを使った話者の自動確定
- 重なり発話からのembedding抽出
- 既存の音声が保存されていない過去データからのembedding生成
- クラウド上の話者認証サービス
- 話者IDを認証やアクセス制御へ利用すること

## 構成

```text
マイク音声
  ├─ Apple SpeechTranscriber ──→ transcription
  └─ FluidAudio Sortformer ────→ speaker_span
                                  │
                                  ├─ 重なりのない3〜10秒を選択
                                  ├─ 短い音声リングバッファから取得
                                  ↓
                              WeSpeaker embedding
                                  │
                     ┌────────────┴────────────┐
                     ↓                         ↓
              永続プロフィールと照合       embeddingを追記保存
                     │
                     ↓
              profileId候補

手動操作: sessionのspeakerIndex → 永続プロフィール
                     │
                     ↓
              mappingを追記保存
                     │
                     ↓
              context出力時に解決
```

SortformerとWeSpeakerを分けることで、Sortformerの低遅延な区間検出を維持したまま、セッションをまたぐ話者識別を追加できる。
現在の`DiarizerTimelineConfig.storeSegments = false`も維持できるため、Sortformer内部の区間配列が長時間セッションで増え続ける問題を再導入しない。

## 音声リングバッファ

`DiarizationStream`へ投入した16kHz mono Float32音声を、サンプル番号付きのchunkとして直近120秒分だけ保持する。
Sortformerの確定区間は同じaudio timelineを使うため、`startSec`と`endSec`をサンプル番号へ変換して元音声を取得できる。

embedding候補は次の条件をすべて満たす区間に限定する。

- 確定済みである
- 3秒以上である
- 他のspeakerIndexの区間と重なっていない
- 同じspeakerIndexの前回候補から30秒以上経過している
- 音声がリングバッファに残っている
- FluidAudioの音声品質検査を通る

上限の10秒は、FluidAudio 0.14.4の[EmbeddingExtractor](https://github.com/FluidInference/FluidAudio/blob/v0.14.4/Sources/FluidAudio/Diarizer/Extraction/EmbeddingExtractor.swift#L117-L140)が16kHz音声を`160,000`sampleの窓で扱い、[DiarizerConfig](https://github.com/FluidInference/FluidAudio/blob/v0.14.4/Sources/FluidAudio/Diarizer/Core/DiarizerTypes.swift#L29-L46)の`chunkDuration`初期値も10秒であることに合わせている。
10秒を超える区間は、1回のembedding抽出をこの標準窓へ収めるため、現在は先頭10秒だけを使う。
ただし、先頭部分が最も話者識別に適している根拠はないため、実測後に区間内で音量と無音率が安定した10秒を選ぶ方法や、複数の10秒窓を評価する方法を検討する。
候補キューにも上限を設け、embeddingモデルが利用できない場合に音声が無制限に残らないようにする。

## 永続データ

大きなembedding配列を通常の`context`へ混ぜないため、`{data-dir}/speakers/`以下へ専用NDJSONとして保存する。
複数端末で同じdata directoryを同期しても競合しにくいよう、日付と端末名でファイルを分ける。

```text
{data-dir}/speakers/
  embeddings/
    2026-08-16_<device>.ndjson
  mappings/
    2026-08-16_<device>.ndjson
```

### speaker_embedding

```json
{
  "id": "2a91f8d8d581",
  "unixTimeMs": 1786838400000,
  "endUnixTimeMs": 1786838408000,
  "sessionId": "a1b2c3d4",
  "speakerId": "a1b2c3d4_0",
  "speakerIndex": 0,
  "device": "Built-in Microphone",
  "durationSec": 8.0,
  "rms": 0.021,
  "embedding": [0.01, -0.02],
  "proposedProfileId": "self",
  "matchDistance": 0.18,
  "matchMargin": 0.22,
  "learnEligible": true,
  "source": {
    "library": "FluidAudio",
    "libraryVersion": "0.14.4",
    "model": "wespeaker_v2",
    "variant": "pyannote_segmentation",
    "dimension": 256,
    "sampleRate": 16000
  }
}
```

embeddingのモデル、variant、次元、sample rate、FluidAudioのmajor/minor versionが異なるデータは同じプロフィール計算へ混ぜない。
patch versionだけが異なる場合は同じモデル契約として扱い、各sampleの完全なversionは診断用に残す。
モデル更新後に過去プロフィールを作り直せるよう、少なくともモデル情報を各sampleへ保存する。

### speaker_mapping

```json
{
  "id": "7bd3491717a9",
  "createdUnixTimeMs": 1786838500000,
  "sessionId": "a1b2c3d4",
  "speakerId": "a1b2c3d4_0",
  "speakerIndex": 0,
  "profileId": "self",
  "fromUnixTimeMs": null,
  "toUnixTimeMs": null,
  "source": "manual"
}
```

同じ範囲に複数のmappingがある場合は、最後に作成された手動mappingを使う。
時間範囲を省略したmappingはセッション全体へ適用する。
時間範囲を指定できるようにし、セッション途中で話者番号が入れ替わった場合にも訂正できるようにする。

## プロフィールの構築と更新

話者プロフィールは永続ID、正解として確認されたembedding、自動追加されたembedding、および正規化した平均embeddingから構成する。

手動mappingに一致するsampleは確認済みデータとして扱う。
手動mappingがないsampleは、過去のプロフィールとの距離が学習用の厳しい基準を満たす場合だけ自動追加する。
自動追加データはプロフィールごとに直近50件までを計算へ使い、確認済みデータは別に保持する。
起動時はembeddingファイルを2回走査し、確認済みデータは合計ベクトルと件数だけをメモリへ持つ。
これにより、保存件数に比例して全embeddingをメモリへ載せない。

照合にはcosine distanceを使う。
初期値として、話者候補を返す最大距離を0.45、自動学習する最大距離を0.35、1位と2位に必要な距離差を0.08とする。
これらはFluidAudioの割り当て基準と更新基準を分離する設計を参考にした保守的な初期値であり、実データで測定して調整する。

手動mappingは常に自動結果より優先する。
自動追加データは、現在の確認済みプロフィール群に対して距離と2位との差を再評価し、現在も同じプロフィールへ十分な差で一致するものだけを使う。
確認済みデータの平均と自動追加データの平均は2対1で合成し、自動データ全体の影響を最大3分の1に抑える。
比較相手が存在しない単一プロフィールでは、強い一致を表示に使うことはあっても自動学習には使わない。
プロフィールは元のembeddingとmappingから再計算するため、mappingを訂正すれば誤って追加されたデータの影響を取り除ける。

## CLI

話者プロフィール操作を`chronixd-capture speakers`へまとめる。

```bash
# セッション内の話者ごとに、発言例、embedding数、現在の候補を確認
chronixd-capture speakers review \
  --data-dir "$DATA_DIR" \
  --session a1b2c3d4

# セッション全体のspeaker 0をselfへ割り当て
chronixd-capture speakers assign \
  --data-dir "$DATA_DIR" \
  --session a1b2c3d4 \
  --speaker-index 0 \
  --profile self

# 時間範囲を限定して訂正
chronixd-capture speakers assign \
  --data-dir "$DATA_DIR" \
  --session a1b2c3d4 \
  --speaker-index 0 \
  --profile other \
  --from 14:30 \
  --to 14:45

# 永続プロフィールと学習sample数を表示
chronixd-capture speakers list --data-dir "$DATA_DIR"

# プロフィールに関連付いたmappingとembeddingを削除
# 実行中プロセスのメモリから再追加されないよう、captureを先に停止する
chronixd-capture speakers forget \
  --data-dir "$DATA_DIR" \
  --profile self \
  --confirm
```

`assign`は既存のcapture NDJSONを書き換えず、新しいmappingを追記する。
`review`、`list`、`forget`はNDJSONを出力し、`jq`などから利用できるようにする。
`forget`は対象プロフィールの手動mapping、そのmappingが現在割り当てるembedding、および対象プロフィールへの自動照合結果を削除する。

## contextでの解決

既存の`speakerId`はデバッグ用のセッション内IDとして残す。
`context`はmappingと確かな自動照合結果を読み、transcriptionとspeaker_spanへ`profileId`を派生フィールドとして追加する。
transcriptionの保存時に話者区間がまだ確定していなかった場合も、`context`は保存済みの`speaker_span`を時間で重ね直し、最も長く重なる`speakerId`を補完する。

```json
{
  "type": "transcription",
  "speakerId": "a1b2c3d4_0",
  "profileId": "self",
  "text": "これで進めようか"
}
```

`context`は永続データそのものを変更しないため、照合方法やmappingを変えた後も再評価できる。
通常の`context`は`speaker_span`を話者解決に使うが、`speaker_span`と`diarization_health`は出力に含めない。
生の区間と診断値を確認するときは`--include-diagnostics`を指定する。

## 長時間運用

音声リングバッファは120秒、Sortformerの重なり判定用区間は5分、embedding候補キューは固定件数に制限する。
永続プロフィールの計算にはすべての確認済みsampleと直近50件の自動sampleを使う。
確認済みsampleはストリーミング集計するため、保存件数に比例してメモリ使用量が増えない。

FluidAudio内部のSortformer timelineは引き続き`maxStoredFrames = 0`、`storeSegments = false`とし、長時間セッションで予測値と区間を二重保持しない。
embeddingモデルのエラーはASRとSortformerを停止させず、標準エラーへ記録して次の候補処理を継続する。
`--no-speaker-identify`を指定した場合は、Sortformerの`speaker_span`とhealth記録だけを継続する。

`speaker_span`はcapture NDJSONへの書き込み成功後にだけ保存済みとして取り除く。
書き込みに失敗した場合は次の周期で再試行する。
NDJSONは`O_APPEND`による1回のwriteと、speakerデータではプロセス間lockを使い、同じ日付・端末のファイルへ複数プロセスが追記しても行の開始位置を共有しない。

`diarization_health`は1分ごとにASRとFluidAudioの最終音声時刻、処理件数、エラーに加え、セッション開始からの実時間と投入音声時間の差`audioWallClockLagSec`を保存する。
FluidAudioの入力待ち行列から古い音声が落ち、時刻を合わせるため無音で補った累計秒数は`diarizationSyntheticSilenceSec`へ保存する。
`--no-diarize`でもASR側の進捗を`status: "disabled"`として保存する。

## 変更ファイル

| ファイル | 変更内容 |
|---|---|
| `SpeakerProfiles.swift` | embedding型、永続store、プロフィール構築、照合、WeSpeaker抽出 |
| `Speakers.swift` | `review`、`assign`、`list`、`forget`コマンド |
| `Diarization.swift` | 音声リングバッファとembedding候補生成 |
| `Capture.swift` | embeddingモデル初期化、候補処理task、終了時flush |
| `Context.swift` | `profileId`の派生解決 |
| `CaptureStore.swift` | session単位のreview用読み取り |
| `ChronixdCapture.swift` | `speakers`サブコマンド登録 |
| `Tests/` | audio timeline、profile builder、mapping、codecのテスト |

## 検証

自動テストでは、音声リングバッファの時間範囲抽出、確定・暫定区間の重なり除外、cosine distance、1位と2位の差、単一プロフィールの自動学習停止、手動mapping優先、ストリーミング再構築、version互換性、永続storeのround-tripと削除を確認する。

実機では2人会話を数分記録し、`speaker_span`とembeddingが保存されることを確認する。
その後`review`と`assign`を実行し、別セッションの`context`に同じ`profileId`が付くか確認する。

「撮るほど改善する」ことは、確認済みsample数を増やしながら、後の時刻にある手動ラベル済みsampleを評価用として取り分けて測定する。
データ量の増加だけで精度向上を断定せず、誤受け入れと未判定の割合を継続して比較する。

## リスク

WeSpeaker用Core MLモデルの初回ダウンロードにより、初回起動が遅くなる。
初期化に失敗した場合はspeaker embeddingだけを無効化し、通常のcaptureを継続する。

自動更新は誤った話者をプロフィールへ混ぜる可能性がある。
認識より厳しい更新基準、1位と2位の距離差、単独話者区間、手動mapping優先によって影響を抑える。

音声モデルを更新するとembedding空間が変わる可能性がある。
sampleへモデル情報を保存し、異なるmodel contractやFluidAudioのmajor/minor versionを混ぜない。

embeddingは元音声そのものではないが、話者を比較するためのデータである。
通常のcontext出力へベクトルを含めず、指定されたdata directory内だけに保存する。
