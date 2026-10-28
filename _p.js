const s = require('fs').readFileSync('index.html', 'utf8');
function show(label, needle, len) { const i = s.indexOf(needle); console.log('--- ' + label + ' @ ' + i); if (i >= 0) console.log(s.slice(i, i + len)); }
show('quickScan', "$('quickScan').onclick", 130);
show('openScan', 'async function openScan', 260);
show('handleScan', 'function handleScan', 420);
