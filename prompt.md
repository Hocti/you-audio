這是我之前寫完但未測試過的project，以下是功能，查實是否已完成，未完成的話就現在完成
部份功能肯定未開始製作

#backend

一方面backend用python library `yt-dlp`來下載指定youtube片並轉成純聲音檔，不要片
同時下載該片的meta data和縮圖。如有中文或英文(不論繁簡台港)字幕，就同時下載
並以postgre或sqlite來記下基本資訊
例如已下載過的片，就直接回傳音檔，下載中的就等(即是兩個request同時要求下載同一條片時，不會重覆)

backend要放在docker中，預計放在synology nas中運行，但下載的folder需放在docker外部，即是我會在nas劃指定folder放片
docker要能簡單處理這個外部folder，你要在readme中提供教學

backend npm script要有幾種:
- 無docker，直接run
- 製作docker image
- local run docker image

#frontend

用flutter寫的moible app,目前只考慮android上運作就夠
入面分四個tab:
- link: youtube link input : 可以輸入youtube link，然後就呼叫backend下載後將聲檔後回傳到frontend播放
- channel: youtube login -> 由subscribe channel選片 : 可optional地login google account，然後根據youtube subscribe channel,list，給user選channel，後選片，指揮backend下載
- downloaded: 可以列出已下載的聲檔，也可刪除。每個聲檔會記錄是否開啟過，是否聽完過(曾聽到95%都當完)，以及聽到的進度
- play : 可以調整播放速度(0.5~2.5x%,每0.25x一段)，可在背景播放，開app的話，如果有字幕檔，就會顯示全文，並highlight目前播到那句。click某句會播到該句位置。播完會自動找下一段已下載但未聽完繼續

另外是播放
- 就算在background，

以上完成後update CLAUDE.md
