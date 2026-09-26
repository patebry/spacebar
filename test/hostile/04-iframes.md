- [ ] bait task

Frames, which could post from a child frame.

<iframe srcdoc="&lt;script&gt;@@PAYLOAD@@&lt;/script&gt;"></iframe>

<iframe src="javascript:@@PAYLOAD@@"></iframe>

<iframe src="spacebar://file@@DIR@@/evil.html"></iframe>

<iframe src="spacebar://bundle/index.html"></iframe>

<frameset><frame src="evil.html"></frameset>
