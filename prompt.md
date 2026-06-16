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

#frontend(folder `flutter_app`)

用flutter寫的mobile app,目前只考慮android上運作就夠
入面分四個tab:
- link: youtube link input : 可以輸入youtube link，然後就呼叫backend下載後將聲檔後回傳到frontend播放
- channel: youtube login -> 由subscribe channel選片 : 可optional地login google account，然後根據youtube subscribe channel,list，給user選channel，後選片，指揮backend下載
- downloaded: 可以列出已下載的聲檔，也可刪除。每個聲檔會記錄是否開啟過，是否聽完過(曾聽到95%都當完)，以及聽到的進度.會顯示片的title.thumbnail,channel name,total time.可以按下馬上播，或長按出context menu，選是放入下一個播或刪除。整個list可以按聽過/未聽,channel,download時間排序和filter.
- play : 可以調整播放速度(0.5~2.5x%,每0.25x一段)，可在背景播放，開app的話，如果有字幕檔，就會顯示全文，並highlight目前播到那句。click某句會播到該句位置。播完會自動找下一段已下載但未聽完繼續

另外是播放
- 以下在background也生效:收到fast forward前後鍵，會跳前後30秒。其餘play/pause,next/prev track和一般app一樣
- 在background例如lockscreen或notification，也要有個ui，顯示目前的audio title,process sider bar，play/prev/next button/時間，這些和一般music app一樣

如以上那部份，例如youtube login有麻煩，要我入token之類，可以暫時整part先不做，先做其他

frontend backend溝通會加密，但backend path和access token只需寫在frontend的env中
要測frontend時我會自動用真實android debug

以上完成後update CLAUDE.md，和readme.md(內容要教我如何setup和測試)
root, frontend,backend要有各自的CLAUDE.md和readme.md
frontend,backend

你先答我以上多少做了，少少未做，然後才跟進