# Localization worklist — brand-rename regression

**Generated:** 2026-08-23 (machine-generated; do not hand-edit, regenerate instead)

## What happened

Renaming the device to **Noop Band** rewrote user-visible sentences that were already translated into
eight locales. The new sentences are not String Catalog keys, so they now render in **English for every
non-English locale**. The previous translations still exist in `Strand/Resources/Localizable.xcstrings`
under the old wording, orphaned.

The strict gate (`python3 Tools/i18n_audit.py --ci HEAD`) currently **passes**, because these literals
were added to `Tools/i18n_audit_baseline.json` rather than extracted: the iOS baseline grew from **57 to
166** entries, **64** of which contain "Noop Band". A baseline is a legitimate tool, but here it made a
shipped regression invisible. `docs/PRODUCTION_READINESS.md` still describes the pre-absorption state.

## Why this was not auto-fixed

The old translations inflect the device as a **common noun with articles and cases**:

| Locale | Old translation of "Use strap alarm time" |
|---|---|
| `de` | Weckzeit des Bands verwenden |
| `es` | Usar la hora de alarma de la pulsera |
| `fr` | Utiliser l’heure d’alarme du bracelet |
| `it` | Usa l’ora della sveglia del dispositivo |
| `pt-PT` | Usar a hora do alarme da pulseira |
| `ru` | Использовать время будильника браслета |
| `zh-Hans` | 使用手环闹钟时间 |
| `zh-Hant` | 使用手環鬧鐘時間 |

Substituting the proper noun "Noop Band" mechanically yields broken grammar — *"de la Noop Band"*,
*"Weckzeit des Noop Band"*, *"du Noop Band"*. Articles must be dropped and cases changed per language.
That is a translator's judgement, so the pairs below are handed over rather than guessed.

## Recommended structural fix (do this once, then renames are free)

Stop baking the brand into translatable sentences. The codebase already has both pieces:
`WhoopModel.customerName` (single source of the name) and the `Platform.deviceNounPhrase` interpolation
pattern. Convert these strings to a placeholder form:

```swift
// before - the brand is inside the translatable sentence, so every rename orphans 8 translations
Text("Connect Noop Band to see live heart rate")

// after - the sentence is brand-free and translated once; the name is injected at runtime
Text(String(format: String(localized: "Connect %@ to see live heart rate"), WhoopModel.customerName))
```

## A. Exact pairs — reuse the existing translation, adjust only the device phrase (22)

### `Noop Band not connected`
- source: `Strand/App/RootView.swift`
- orphaned key with translations: `Strap not connected`
  - `de`: Strap nicht verbunden
  - `es`: Pulsera no conectada
  - `fr`: Bracelet non connecté
  - `it`: Fascia non collegata
  - `pt-PT`: Correia não ligada
  - `ru`: Браслет не подключён
  - `zh-Hans`: 手环未连接
  - `zh-Hant`: 手環未連接

### `Connect Noop Band to see live heart rate`
- source: `Strand/Liquid/LiquidTodayView.swift`
- orphaned key with translations: `Connect your strap to see live heart rate`
  - `de`: Verbinde deinen Strap, um die Live-Herzfrequenz zu sehen
  - `es`: Conecta tu pulsera para ver la frecuencia cardíaca en vivo
  - `fr`: Connectez votre bracelet pour voir la fréquence cardiaque en direct
  - `it`: Collega la tua fascia per vedere la frequenza cardiaca in diretta
  - `pt-PT`: Ligue a tua bracelete para ver a frequência cardíaca em direto
  - `ru`: Подключите браслет, чтобы видеть пульс в реальном времени
  - `zh-Hans`: 连接你的手环以查看实时心率
  - `zh-Hant`: 連接你的手環以查看即時心率

### `Noop Band battery`
- source: `Strand/Liquid/LiquidTodayView.swift`
- orphaned key with translations: `Strap battery`
  - `de`: Strap-Akku
  - `es`: Batería de la pulsera
  - `fr`: Batterie du bracelet
  - `it`: Batteria della fascia
  - `pt-PT`: Bateria de pega
  - `ru`: Батарея браслета
  - `zh-Hans`: 手环电量
  - `zh-Hant`: 手環電量

### `Start a live session. Beta. Silent Noop Band coaching against today's Recovery.`
- source: `Strand/Liquid/LiquidTodayView.swift`
- orphaned key with translations: `Start a live session. Beta. Silent strap coaching against today's Recovery.`
  - `de`: Starten Sie eine Live-Sitzung. Beta. Silent-Strap-Coaching gegen die heutige Erholung.
  - `es`: Iniciar una sesión en vivo. Beta. Entrenamiento silencioso con correa contra la recuperación de hoy.
  - `fr`: Démarrez une session en direct. Bêta. Coaching silencieux contre la reprise d'aujourd'hui.
  - `pt-PT`: Inicie uma sessão em direto. Beta. Treino silencioso contra a recuperação de hoje.

### `Noop Band not connected`
- source: `Strand/MenuBar/MenuBarContent.swift`
- orphaned key with translations: `Strap not connected`
  - `de`: Strap nicht verbunden
  - `es`: Pulsera no conectada
  - `fr`: Bracelet non connecté
  - `it`: Fascia non collegata
  - `pt-PT`: Correia não ligada
  - `ru`: Браслет не подключён
  - `zh-Hans`: 手环未连接
  - `zh-Hant`: 手環未連接

### `When the system prompt appears, choose Allow so NOOP can find Noop Band.`
- source: `Strand/Onboarding/OnboardingWizard.swift`
- orphaned key with translations: `When the system prompt appears, choose Allow so NOOP can find your strap.`
  - `de`: Wenn die Systemabfrage erscheint, wähle „Erlauben“, damit NOOP deinen Strap finden kann.
  - `es`: Cuando aparezca el aviso del sistema, elige Permitir para que NOOP pueda encontrar tu pulsera.
  - `fr`: Quand la demande système apparaît, choisissez Autoriser pour que NOOP puisse trouver votre bracelet.
  - `it`: Quando appare la richiesta di sistema, scegli Consenti così NOOP può trovare la tua fascia.
  - `pt-PT`: Quando o prompt do sistema for apresentado, escolha Permitir para que o NOOP possa encontrar a tua bracelete.
  - `ru`: Когда появится системный запрос, выберите «Разрешить», чтобы NOOP мог найти ваш браслет.
  - `zh-Hans`: 当系统提示出现时，请选择「允许」，以便 NOOP 找到你的手环。
  - `zh-Hant`: 當系統提示出現時，請選擇「允許」，以便 NOOP 找到你的手環。

### `Connect Noop Band. Calm me is a felt rhythm on the wrist, so it needs a bonded connection.`
- source: `Strand/Screens/BreathingView.swift`
- orphaned key with translations: `Connect your strap. Calm me is a felt rhythm on the wrist, so it needs a bonded connection.`
  - `de`: Verbinde deinen Strap. „Beruhige mich“ ist ein spürbarer Rhythmus am Handgelenk und braucht daher eine gekoppelte Verbindung.
  - `es`: Conecta tu pulsera. Cálmame es un ritmo que se siente en la muñeca, así que necesita una conexión vinculada.
  - `fr`: Connectez votre bracelet. Apaisez-moi est un rythme ressenti au poignet, cela nécessite donc une connexion associée.
  - `it`: Collega la tua fascia, Calmami è un ritmo percepito sul polso, quindi necessita di una connessione associata.
  - `pt-PT`: Ligue a tua bracelete. Acalmar é um ritmo sentido no pulso, por isso precisa de uma ligação forte.
  - `ru`: Подключите браслет. Функция «Успокоить меня» - это тактильный ритм на запястье, поэтому нужно привязанное соединение.
  - `zh-Hans`: 连接你的手环 ，「让我平静」是手腕上可感知的节律，因此需要已绑定的连接。
  - `zh-Hant`: 連接你的手環 ，「讓我平靜」是手腕上可感知的節律，因此需要已綁定的連接。

### `Not enough clean beat data to lock a pace today. Try again rested, sitting still with Noop Band snug. For now we'll pace you at 5.5 br/min (coherence).`
- source: `Strand/Screens/BreathingView.swift`
- orphaned key with translations: `Not enough clean beat data to lock a pace today. Try again rested, sitting still with the strap snug. For now we'll pace you at 5.5 br/min (coherence).`
  - `de`: Nicht genug saubere Schlagdaten, um heute ein Tempo zu fixieren. Versuch es ausgeruht erneut, still sitzend mit eng anliegendem Strap. Vorerst takten wir dich mit 5,5 AZ/min (Kohärenz).
  - `es`: No hay suficientes latidos limpios para fijar un ritmo hoy. Vuelve a intentarlo descansado, sentado y quieto con la pulsera bien ajustada. Por ahora te marcaremos un ritmo de 5.5 resp/min (coherencia).
  - `fr`: Pas assez de battements propres pour fixer un rythme aujourd'hui. Réessayez reposé, assis immobile avec le bracelet bien ajusté. Pour l'instant, nous vous cadencerons à 5,5 resp/min (cohérence).
  - `it`: Dati sui battiti puliti insufficienti per fissare un ritmo oggi, riprova da riposato, stando seduto e immobile con la fascia ben aderente. Per ora ti guideremo a 5,5 resp/min (coerenza).
  - `pt-PT`: Não há dados suficientes de batida limpa para travar o ritmo hoje. Tente novamente descansado, sentado imóvel com a pega bem ajustada. Para já, vamos definir um ritmo de 5,5 br/min (coerência).
  - `ru`: Недостаточно чистых данных пульса, чтобы задать сегодня темп. Повторите в отдохнувшем состоянии, сидя неподвижно, с плотно надетым браслетом. Пока будем задавать темп 5.5 вдох/мин (когерентность).
  - `zh-Hans`: 今天没有足够干净的心跳数据来锁定一个节奏，请在休息好、坐姿静止、手环贴合时重试。目前我们会以 5.5 次/分钟（一致性）为你把握节奏。
  - `zh-Hant`: 今天沒有足夠乾淨的心跳資料來鎖定一個節奏，請在休息好、坐姿靜止、手環貼合時重試。目前我們會以 5.5 次/分鐘（一致性）為你把握節奏。

### `Wear Noop Band overnight to score a night first.`
- source: `Strand/Screens/CoupledView.swift`
- orphaned key with translations: `Wear the strap overnight to score a night first.`
  - `de`: Trage den Strap über Nacht, um zuerst eine Nacht zu bewerten.
  - `es`: Use la correa durante la noche para anotar una noche primero.
  - `fr`: Portez la sangle toute la nuit pour marquer une nuit en premier.
  - `pt-PT`: Use a bracelete durante a noite para marcar uma noite primeiro.
  - `ru`: Сначала наденьте браслет на ночь, чтобы получить оценку сна.

### `No live heart rate yet. Open Live to pair Noop Band.`
- source: `Strand/Screens/DataSourcesView.swift`
- orphaned key with translations: `No live heart rate yet. Open Live to pair your strap.`
  - `de`: Noch keine Live-Herzfrequenz. Öffne Live, um deinen Strap zu koppeln.
  - `es`: Aún no hay frecuencia cardíaca en vivo. Abre En vivo para emparejar tu pulsera.
  - `fr`: Aucune fréquence cardiaque en direct pour l'instant. Ouvrez En direct pour associer votre bracelet.
  - `it`: Ancora nessuna frequenza cardiaca in diretta. Apri In diretta per abbinare la tua fascia.
  - `pt-PT`: Ainda não há frequência cardíaca em direto. Abra o Live para emparelhar a tua bracelete.
  - `ru`: Пульса в реальном времени пока нет. Откройте Live, чтобы сопрячь браслет.
  - `zh-Hans`: 尚无实时心率。打开「实时」以配对你的手环。
  - `zh-Hant`: 尚無即時心率。打開「即時」以配對你的手環。

### `Restart Noop Band…`
- source: `Strand/Screens/DevicesView.swift`
- orphaned key with translations: `Restart strap…`
  - `de`: Band neu starten ...
  - `es`: Correa de reinicio...
  - `fr`: Redémarrer la sangle...
  - `pt-PT`: Reinicie a bracelete…

### `An HRV reading needs the live R-R stream. Open the Live screen and connect Noop Band, then come back.`
- source: `Strand/Screens/HRVSnapshotView.swift`
- orphaned key with translations: `An HRV reading needs the live R-R stream. Open the Live screen and connect your strap, then come back.`
  - `de`: Eine HRV-Messung braucht den Live-R-R-Stream. Öffne den Live-Bildschirm und verbinde deinen Strap, dann komm zurück.
  - `es`: Una lectura de VFC necesita el flujo R-R en vivo. Abre la pantalla En vivo y conecta tu pulsera, luego vuelve.
  - `fr`: Une lecture de VFC nécessite le flux R-R en direct. Ouvrez l'écran En direct et connectez votre bracelet, puis revenez.
  - `it`: Una lettura HRV richiede lo stream R-R in diretta. Apri la schermata In diretta e connetti la tua fascia, poi torna qui.
  - `pt-PT`: Uma leitura HRV precisa da transmissão RR em direto. Abra o ecrã em direto, ligue a tua bracelete e volte.
  - `ru`: Для показания ВСР нужен живой поток R-R. Откройте экран «Прямой эфир», подключите браслет и вернитесь сюда.
  - `zh-Hans`: HRV 读数需要实时 R-R 数据流。请打开「实时」界面并连接你的手环，然后再返回。
  - `zh-Hant`: HRV 讀數需要即時 R-R 資料流。請打開「即時」畫面並連接你的手環，然後再返回。

### `NOOP never shows you a number it had to make up. If a score isn't ready, it tells you why and what to do next. Everything here runs on your device, from Noop Band.`
- source: `Strand/Screens/HowNoopWorksView.swift`
- orphaned key with translations: `NOOP never shows you a number it had to make up. If a score isn't ready, it tells you why and what to do next. Everything here runs on your device, from your strap.`
  - `de`: NOOP zeigt dir nie eine Zahl, die es erfinden musste. Wenn ein Wert nicht bereit ist, sagt es dir, warum und was als Nächstes zu tun ist. Alles hier läuft auf deinem Gerät, von deinem Strap.
  - `es`: NOOP nunca te muestra un número que haya tenido que inventar. Si una puntuación no está lista, te dice por qué y qué hacer a continuación. Todo aquí se ejecuta en tu dispositivo, desde tu pulsera.
  - `fr`: NOOP ne vous montre jamais un chiffre qu'il a dû inventer. Si un score n'est pas prêt, il vous dit pourquoi et quoi faire ensuite. Tout ici s'exécute sur votre appareil, depuis votre bracelet.
  - `it`: NOOP non ti mostra mai un numero che ha dovuto inventare. Se un punteggio non è pronto, ti dice perché e cosa fare dopo. Tutto qui funziona sul tuo dispositivo, dalla tua fascia.
  - `pt-PT`: O NOOP nunca mostra um número que precisava de ser inventado. Se uma pontuação não estiver pronta, diz-lhe porquê e o que fazer a seguir. Tudo aqui funciona no teu dispositivo, na tua bracelete.
  - `ru`: NOOP никогда не показывает придуманное значение. Если показатель ещё не готов, он объясняет почему и что делать дальше. Всё здесь работает на вашем устройстве, на основе данных браслета.
  - `zh-Hans`: NOOP 绝不会向你显示它不得不编造的数字。如果某个评分尚未就绪，它会告诉你原因以及下一步该怎么做。这里的一切都在你的设备上运行，源自你的手环。
  - `zh-Hant`: NOOP 絕不會向你顯示它不得不編造的數字。如果某個評分尚未就緒，它會告訴你原因以及下一步該怎麼做。這裡的一切都在你的裝置上運行，源自你的手環。

### `High-rate, beat-by-beat tracking uses more Noop Band and phone battery. It runs only while this Live screen and NOOP are in the foreground.`
- source: `Strand/Screens/LiveView.swift`
- orphaned key with translations: `High-rate, beat-by-beat tracking uses more strap and phone battery. It runs only while this Live screen and NOOP are in the foreground.`
  - `de`: Die schnelle, taktweise Verfolgung verbraucht mehr Armband und Telefonbatterie. Es läuft nur, während dieser Live-Bildschirm und NOOP im Vordergrund sind.
  - `es`: El seguimiento de alta velocidad, latido a latido, utiliza más correa y batería del teléfono. Se ejecuta únicamente mientras esta pantalla en vivo y NOOP están en primer plano.
  - `fr`: Le suivi battement par battement à haut débit utilise davantage de sangle et de batterie de téléphone. Il ne fonctionne que lorsque cet écran Live et NOOP sont au premier plan.
  - `pt-PT`: O rastreio de alta taxa, batida a batida, utiliza mais pulseira e bateria do telefone. É executado apenas enquanto o ecrã ao vivo e o NOOP estiverem em primeiro plano.

### `Kick in at (Noop Band battery)`
- source: `Strand/Screens/SettingsView.swift`
- orphaned key with translations: `Kick in at (strap battery)`
  - `de`: Aktiv ab (Band-Akku)
  - `es`: Pase en (la batería del freno)
  - `fr`: Démarrage à (batterie)
  - `pt-PT`: Pontapé em (bateria da bracelete)
  - `zh-Hans`: 触发条件 (手环电量)

### `No days yet where both NOOP and your phone counted steps. Once your phone logs a few days alongside Noop Band, they'll appear here so you can see how close the estimate is.`
- source: `Strand/Screens/SettingsView.swift`
- orphaned key with translations: `No days yet where both NOOP and your phone counted steps. Once your phone logs a few days alongside the strap, they'll appear here so you can see how close the estimate is.`
  - `de`: Noch keine Tage, an denen sowohl NOOP als auch dein Telefon Schritte gezählt haben. Sobald dein Telefon ein paar Tage neben dem Strap protokolliert, erscheinen sie hier, damit du siehst, wie nah die Schätzung ist.
  - `es`: Aún no hay días en los que tanto NOOP como tu teléfono hayan contado pasos. Cuando tu teléfono registre unos días junto con la pulsera, aparecerán aquí para que veas qué tan cerca está la estimación.
  - `fr`: Aucun jour pour l'instant où NOOP et votre téléphone ont tous deux compté des pas. Une fois que votre téléphone aura enregistré quelques jours en parallèle du bracelet, ils apparaîtront ici pour que vous puissiez voir à quel point l'estimation est précise.
  - `it`: Ancora nessun giorno in cui sia NOOP che il tuo telefono abbiano contato i passi. Una volta che il tuo telefono registrerà qualche giorno insieme alla fascia, appariranno qui così potrai vedere quanto è precisa la stima.
  - `pt-PT`: Ainda não há dias em que o NOOP e o teu telemóvel contem passos. Assim que o teu telemóvel registar alguns dias ao lado da bracelete, eles aparecerão aqui para que possa ver o quão próxima está a estimativa.
  - `ru`: Пока нет дней, когда шаги считали и NOOP, и телефон. Как только телефон запишет несколько дней вместе с браслетом, они появятся здесь, чтобы вы могли увидеть, насколько точна оценка.
  - `zh-Hans`: 还没有 NOOP 和你手机同时统计步数的日期。一旦你的手机与手环一起记录了几天，它们就会出现在这里，让你看到估算有多接近。
  - `zh-Hant`: 還沒有 NOOP 和你手機同時統計步數的日期。一旦你的手機與手環一起記錄了幾天，它們就會出現在這裡，讓你看到估算有多接近。

### `Noop Band accepted all 15 R22 flags`
- source: `Strand/Screens/SettingsView.swift`
- orphaned key with translations: `Strap accepted all 15 R22 flags`
  - `de`: Strap hat alle 15 R22-Flags akzeptiert
  - `es`: La pulsera aceptó los 15 indicadores R22
  - `fr`: Le bracelet a accepté les 15 indicateurs R22
  - `it`: La fascia ha accettato tutti i 15 flag R22
  - `pt-PT`: Bracelete aceitou todas as 15 flags R22
  - `ru`: Браслет принял все 15 флагов R22
  - `zh-Hans`: 手环已接受全部 15 个 R22 标志位
  - `zh-Hant`: 手環已接受全部 15 個 R22 旗標

### `Replaces the Today tab with the prototype redesign. Turn it off any time to return to the classic dashboard. Reads the same live data from Noop Band.`
- source: `Strand/Screens/SettingsView.swift`
- orphaned key with translations: `Replaces the Today tab with the prototype redesign. Turn it off any time to return to the classic dashboard. Reads the same live data from your strap.`
  - `de`: Ersetzt die Registerkarte Heute durch das Prototyp-Redesign. Schalten Sie es jederzeit aus, um zum klassischen Dashboard zurückzukehren. Lies die gleichen live-daten von deinem strap.
  - `es`: Reemplaza la pestaña Hoy con el prototipo de rediseño. Apágalo en cualquier momento para volver al panel clásico. Lea los mismos datos en vivo de su correa.
  - `fr`: Remplace l'onglet Aujourd'hui par la refonte du prototype. Éteignez-le à tout moment pour revenir au tableau de bord classique. Lis les mêmes données en direct de votre sangle.
  - `pt-PT`: Substitui o separador Hoje pelo redesenho do protótipo. Desligue-o a qualquer momento para voltar ao painel clássico. Lê os mesmos dados em direto da tua bracelete.

### `Silence-first Noop Band coaching during workouts.`
- source: `Strand/Screens/SettingsView.swift`
- orphaned key with translations: `Silence-first strap coaching during workouts.`
  - `de`: Silence-first strap coaching während des workouts.
  - `es`: Entrenamiento de correa silenciosa durante ejercicios.
  - `fr`: Entraînement silence-première sangle pendant les séances d'entraînement.
  - `pt-PT`: Treino com bracelete silenciosa durante os treinos.

### `No nights with sleep data yet. Your ledger fills in as you wear Noop Band to bed.`
- source: `Strand/Screens/SleepView.swift`
- orphaned key with translations: `No nights with sleep data yet. Your ledger fills in as you wear the strap to bed.`
  - `de`: Noch keine Nächte mit Schlafdaten. Deine Bilanz füllt sich, wenn du den Strap im Bett trägst.
  - `es`: Aún no hay noches con datos de sueño. Tu registro se irá llenando a medida que duermas con la pulsera puesta.
  - `fr`: Aucune nuit avec des données de sommeil pour l'instant. Votre registre se remplit à mesure que vous portez le bracelet pour dormir.
  - `it`: Ancora nessuna notte con dati sul sonno, il tuo registro si riempie man mano che indossi la fascia a letto.
  - `pt-PT`: Ainda não há noites com dados de sono. O teu livro-razão é preenchido à medida que usa a pega para dormir.
  - `ru`: Ночей с данными о сне пока нет. История будет пополняться по мере того, как вы носите браслет во время сна.
  - `zh-Hans`: 尚无有睡眠数据的夜晚，随着你佩戴手环入睡，你的记录会逐渐填满。
  - `zh-Hant`: 尚無有睡眠資料的夜晚，隨著你佩戴手環入睡，你的記錄會逐漸填滿。

### `Use Noop Band alarm time`
- source: `Strand/Screens/SmartAlarmView.swift`
- orphaned key with translations: `Use strap alarm time`
  - `de`: Weckzeit des Bands verwenden
  - `es`: Usar la hora de alarma de la pulsera
  - `fr`: Utiliser l’heure d’alarme du bracelet
  - `it`: Usa l’ora della sveglia del dispositivo
  - `pt-PT`: Usar a hora do alarme da pulseira
  - `ru`: Использовать время будильника браслета
  - `zh-Hans`: 使用手环闹钟时间
  - `zh-Hant`: 使用手環鬧鐘時間

### `Wire NOOP's actions into a Back-Tap, a focus automation, or a longer Shortcut. For example, double-tap the back of your iPhone to buzz Noop Band.`
- source: `StrandiOS/App/SiriShortcutsSettingsView.swift`
- orphaned key with translations: `Wire NOOP's actions into a Back-Tap, a focus automation, or a longer Shortcut. For example, double-tap the back of your iPhone to buzz the strap.`
  - `de`: Verdrahte NOOPs Aktionen mit einem Back-Tap, einer Fokus-Automation oder einem längeren Kurzbefehl. Zum Beispiel: Doppeltippe auf die Rückseite deines iPhones, um den Strap vibrieren zu lassen.
  - `es`: Conecta las acciones de NOOP a un toque trasero, una automatización de concentración o un atajo más largo. Por ejemplo, toca dos veces la parte trasera de tu iPhone para hacer vibrar la pulsera.
  - `fr`: Connectez les actions de NOOP à un Toucher dos, une automatisation de concentration, ou un raccourci plus long. Par exemple, touchez deux fois l'arrière de votre iPhone pour faire vibrer le bracelet.
  - `it`: Collega le azioni di NOOP a un Tocco posteriore, a un'automazione di un Focus o a uno Shortcut più lungo, per esempio, tocca due volte il retro del tuo iPhone per far vibrare la fascia.
  - `pt-PT`: Ligue as ações do NOOP num Back-Tap, numa automação de foco ou num atalho mais longo. Por exemplo, toque duas vezes na parte de trás do teu iPhone para movimentar a pega.
  - `ru`: Свяжите действия NOOP с двойным нажатием по задней панели, автоматизацией фокусирования или более длинным ярлыком. Например, дважды нажмите по задней панели iPhone, чтобы браслет завибрировал.
  - `zh-Hans`: 将 NOOP 的操作接入轻点背面、专注模式自动化或更长的快捷指令，例如，双击你 iPhone 的背面来让手环震动。
  - `zh-Hant`: 將 NOOP 的操作接入輕點背面、專注模式自動化或更長的捷徑，例如，雙擊你 iPhone 的背面來讓手環震動。

## B. Near matches — verify before reuse (14)

- `Noop Band reminders use the schedule below. They do not need notification permission, but iOS cannot guarantee a Bluetooth vibration while NOOP is suspended or terminated.`  
  source `Strand/Screens/AutomationsView.swift`  
  likely predecessor `Strap-only reminders use the schedule below. They do not need notification permission, but iOS cannot guarantee a Bluetooth buzz while NOOP is suspended or terminated.`
- `Connect Noop Band for haptic guidance. You'll feel one pulse on the inhale and two on the exhale, so you can breathe with your eyes closed.`  
  source `Strand/Screens/BreathingView.swift`  
  likely predecessor `Connect your strap for haptic guidance. You'll feel one pulse on the inhale, two on the exhale, so you can breathe with your eyes closed.`
- `Connect Noop Band for the felt cue. The sweep paces you with one vibration on the inhale and two on the exhale.`  
  source `Strand/Screens/BreathingView.swift`  
  likely predecessor `Connect your strap for the felt cue. The sweep paces you with one buzz on the inhale, two on the exhale.`
- `Noop Band vibrates a gentle rhythm just below your current heart rate, a felt metronome to relax toward. It trails your heart down rather than yanking it and stops on its own.`  
  source `Strand/Screens/BreathingView.swift`  
  likely predecessor `The strap buzzes a gentle rhythm just below your current heart rate, a felt metronome to relax toward. It trails your heart down rather than yanking it, and stops on its own.`
- `Connect a Noop Band, Apple Watch, heart-rate strap, ring, or supported gym machine. NOOP will show only the signals that device actually provides.`  
  source `Strand/Screens/DevicesView.swift`  
  likely predecessor `Connect a WHOOP, Apple Watch, heart-rate strap, ring, or supported gym machine. NOOP will show only the signals that device actually provides.`
- `A 60-second snapshot of beat-to-beat (R-R) intervals from Noop Band, cleaned with range and ectopic-beat filtering before computing RMSSD the same way your overnight HRV is computed.`  
  source `Strand/Screens/HRVSnapshotView.swift`  
  likely predecessor `A 60-second snapshot of your beat-to-beat (R-R) intervals from the strap, cleaned (range and ectopic-beat filtering) before computing RMSSD the same way your overnight HRV is computed.`
- `Recovery weighs your HRV against your personal baseline (~55%), resting heart rate (~20%), sleep quality (~15%), respiration (~5%) and skin-temperature deviation (~5%). Effort is a 0-\(UnitFormatter.effortScaleMax(effortScale)) cardiovascular load from time in heart-rate zones. Sleep is staged from movement and heart rate. Everything is computed here from Noop Band's raw data. It works for any day NOOP collected raw streams.`  
  source `Strand/Screens/IntelligenceView.swift`  
  likely predecessor `Recovery weighs your HRV against your personal baseline (~55%%), resting heart rate (~20%%), sleep quality (~15%%), respiration (~5%%) and skin-temperature deviation (~5%%). Effort is a 0-%@ cardiovascular load from time in heart-rate zones. Sleep is staged from movement and heart rate. Everything is computed here from the strap's raw data. It works for any day NOOP collected raw streams.`
- `Pair Noop Band on the Live screen to feel the transitions hands-free.`  
  source `Strand/Screens/IntervalTimerView.swift`  
  likely predecessor `Bond your strap on the Live screen to feel the transitions hands-free.`
- `Can't connect: Noop Band pairing was reset`  
  source `Strand/Screens/LiveView.swift`  
  likely predecessor `Can't connect: your strap's pairing was reset`
- `Keeps the detailed beat-to-beat heart-rate stream running all day and night, not just while a live screen is open, so NOOP captures much more for overnight HRV, recovery and sleep. Uses more battery because Noop Band streams heart rate continuously while connected.`  
  source `Strand/Screens/SettingsView.swift`  
  likely predecessor `Keeps the detailed beat-to-beat heart-rate stream running all day and night, not just while a live screen is open, so NOOP captures much more for overnight HRV, recovery and sleep. Uses more battery: your strap streams heart rate continuously while connected.`
- `Noop Band isn't accepting the alarm`  
  source `Strand/Screens/SmartAlarmView.swift`  
  likely predecessor `Your strap isn't accepting the alarm`
- `Once NOOP has a fresh detected sleep session, it arms Noop Band for the projected target and revises that time as awake minutes accumulate. The band can still vibrate with NOOP closed after it has been armed; detecting and revising the target remains best-effort in the background.`  
  source `Strand/Screens/SmartAlarmView.swift`  
  likely predecessor `Once NOOP has a fresh detected sleep session, it arms the strap for the projected target and revises that time as awake minutes accumulate. The strap can still buzz with NOOP closed after it has been armed; detecting and revising the target remains best-effort in the background.`
- `The Noop Band alarm is a silent vibration, not a sound`  
  source `Strand/Screens/SmartAlarmView.swift`  
  likely predecessor `The strap alarm is a silent buzz, not a sound`
- `Buzz Noop Band or mark a moment from Siri, Spotlight, the Shortcuts app, or a Back-Tap automation. No setup needed.`  
  source `StrandiOS/App/SiriShortcutsSettingsView.swift`  
  likely predecessor `Buzz your strap or mark a moment from Siri, Spotlight, the Shortcuts app, or a Back-Tap / automation. No setup needed.`

## C. No predecessor — needs fresh translation (28)

- `A private window into your recovery, sleep and strain. Read straight from Noop Band and kept only on \(Platform.deviceNounPhrase).`  
  source `Strand/Onboarding/OnboardingWizard.swift`
- `Some Noop Band firmware features are still experimental in NOOP.`  
  source `Strand/Screens/AddDeviceWizard.swift`
- `Noop Band ECG spot recording (experimental)`  
  source `Strand/Screens/DevicesView.swift`
- `Noop Band is NOOP's fully supported band. Other heart-rate straps can stream live heart rate and HRV, but they do not provide the deeper nightly signals available from Noop Band.`  
  source `Strand/Screens/DevicesView.swift`
- `No overlap yet between this marker and \(signal?.title.lowercased() ?? String(localized: "that signal")). Log a few more readings and keep wearing Noop Band.`  
  source `Strand/Screens/LabBookView.swift`
- `Live HR works. Re-pair Noop Band to unlock haptics, alarms, and sync`  
  source `Strand/Screens/LiveView.swift`
- `Broadcast HR is on. Noop Band is advertising heart rate continuously, which uses more battery. Turn it off when you are not using it with another device.`  
  source `Strand/Screens/SettingsView.swift`
- `Broadcast Noop Band HR`  
  source `Strand/Screens/SettingsView.swift`
- `Changes the Bluetooth name Noop Band advertises when pairing. The band restarts to apply it, so the new name appears on the next connection. Available only on supported firmware.`  
  source `Strand/Screens/SettingsView.swift`
- `Compatible Noop Band firmware may require feature flags before it emits high-rate heart rate, motion, and history. This reversible control writes that experimental enable sequence to the band. It may do nothing on your firmware and is available from iPhone or Android only.`  
  source `Strand/Screens/SettingsView.swift`
- `Counter ticks per step. Leave at 1.0 unless your steps run high. Some Noop Band firmware reports a high-rate motion counter, so this goes up to 30. Walk a known 1,000 steps and divide NOOP's count by the real count to get your value.`  
  source `Strand/Screens/SettingsView.swift`
- `Makes compatible Noop Band hardware advertise heart rate as a standard Bluetooth sensor for Garmin, Zwift, or gym equipment. The reversible setting applies on the next connection and is available from iPhone only.`  
  source `Strand/Screens/SettingsView.swift`
- `NOOP estimates steps from Noop Band motion, calibrated to your phone. It remains an estimate, not a measured step count.`  
  source `Strand/Screens/SettingsView.swift`
- `NOOP estimates steps from Noop Band motion, calibrated to your phone. This firmware needs advanced band data enabled before motion is available.`  
  source `Strand/Screens/SettingsView.swift`
- `Noop Band ECG spot recording (experimental)`  
  source `Strand/Screens/SettingsView.swift`
- `Noop Band accepted \(live.r22FlagsAccepted)/15 R22 flags…`  
  source `Strand/Screens/SettingsView.swift`
- `Noop Band · motion to steps`  
  source `Strand/Screens/SettingsView.swift`
- `On ECG-capable Noop Band hardware, this unlocks a user-started 30-second protocol spot recording in Devices. It cannot monitor continuously. Keep the opposite hand touching both clasp electrodes for the full recording. NOOP refuses to send unless the hardware positively identifies ECG support; the command is unvalidated and may do nothing.`  
  source `Strand/Screens/SettingsView.swift`
- `On compatible Noop Band hardware, NOOP sends an advanced real-time stream request after the handshake and logs the response for protocol validation.`  
  source `Strand/Screens/SettingsView.swift`
- `Reviews each scored wake block for real evidence of getting up (walking cadence, a change in body position) instead of just a heart-rate rise. A wake block with no locomotion and a stable posture - a hot night, a brief turn-over - is folded back into light sleep; a real get-up is left alone. It checks how much motion detail Noop Band actually recorded and stays off when a night is too sparse to trust. Off by default; takes effect on the next nights staged.`  
  source `Strand/Screens/SettingsView.swift`
- `Slows background band sync (every 45 min instead of 15) while Noop Band's battery is low. No data is lost because the band keeps banking readings and syncs them in larger, less frequent pulls.`  
  source `Strand/Screens/SettingsView.swift`
- `The companion for Noop Band. Your history, live stream, and numbers stay on this device by default. Data leaves only through features you explicitly enable, such as your own self-hosted sync.`  
  source `Strand/Screens/SettingsView.swift`
- `When Noop Band does not expose a measured step count, NOOP estimates steps from motion and calibrates them to your phone. Tap to review and adjust the estimate.`  
  source `Strand/Screens/SettingsView.swift`
- `While Noop Band's battery is low, stop the always-on background HRV stream, the biggest continuous drain on the band. A Live screen still shows heart rate, and capture re-arms automatically once the band is charged.`  
  source `Strand/Screens/SettingsView.swift`
- `Noop Band keeps reporting a different time than NOOP sends, so its alarm may not fire at your wake time. Restart the band from Devices, or fully charge it and reconnect. Keep your phone's Clock alarm as your wake until the band accepts the time.`  
  source `Strand/Screens/SmartAlarmView.swift`
- `Noop Band provides a silent wrist vibration. Fixed-time alarms stay on the band once armed. Detected-sleep alarms are revised when fresh sleep data reaches NOOP, so background timing depends on Bluetooth sync and iOS scheduling. The phone backup is a normal notification, not a guaranteed loud alarm; Focus or silent mode can suppress it. Keep a Clock alarm for anything you cannot miss.`  
  source `Strand/Screens/SmartAlarmView.swift`
- `Noop Band battery \(Int(pct.rounded())) percent\(live.charging == true ? ", charging" : "")\(estimateText.map { ", \($0)" } ?? "")`  
  source `Strand/Screens/TodayView.swift`
- `Estimated from Noop Band motion, calibrated to your phone. Not a measured step count.`  
  source `StrandiOS/App/ShortcutExportSettingsView.swift`

## Definition of done

1. Each string above is a String Catalog key (placeholder form preferred) with all eight locales.
2. Its entry is removed from `Tools/i18n_audit_baseline.json` — the baseline must **shrink**, never grow.
3. `python3 Tools/i18n_audit.py --ci HEAD` still passes, and `StrandTests/BrandLiteralRatchetTests` shows
   a lower count.
4. The orphaned old keys are deleted from the catalog.
5. `docs/PRODUCTION_READINESS.md` localization row is updated to the real state.
