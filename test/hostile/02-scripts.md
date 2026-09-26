- [ ] bait task

Script elements, inline and from files beside the document.

<script>@@PAYLOAD@@</script>

<script src="evil.js"></script>

<script src="spacebar://file@@DIR@@/evil.js"></script>

<script src="spacebar://bundle/..%2f..%2f..%2f..%2f..%2f..%2f..%2f..%2f..%2f..%2f..%2f..%2f@@DIRREL@@/evil.js"></script>

<base href="spacebar://file@@DIR@@/"><script src="evil.js"></script>

<object data="evil.html"></object> <embed src="evil.js">

<link rel="import" href="evil.html"><link rel="stylesheet" href="https://pwned.invalid/style.css">
