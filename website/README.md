# benni.tech

Plain static site: hand-written HTML + one CSS file. No build step, no
JavaScript, no web fonts, no external requests.

```
index.html      first page + short dated notes (fefe-style)
cv.html         CV
projects.html   projects
contact.html    contact
style.css       all styling; colours are CSS variables at the top (light + dark)
ping.txt        "ok\n" — tiny connectivity-check endpoint
```

## Add a note

Add one `<li>` at the top of the list in `index.html`:

```html
<li><span class="date">2026-10-06</span> Text of the note. <a href="...">link</a></li>
```

## Add a page

Copy `cv.html`, change `<title>` and the content, add a link in the `<nav>` of
every page.

## Preview locally

```sh
cd website && python3 -m http.server 8000   # or: busybox httpd -f -p 8000
```

## Deploy

Copy the files to any static web server document root, e.g.:

```sh
rsync -av --delete --exclude README.md website/ user@host:/var/www/benni.tech/
```

## Use as an Internet check

The site is static and tiny, so it answers fast and works as a reachability probe:

```sh
curl -fsS --max-time 5 https://benni.tech/ping.txt   # prints "ok" when online
```

Exit code 0 = online. For quick checks the 3-byte `ping.txt` is cheaper than
`index.html`. Serve it with caching disabled so a proxy/cache can't answer for
a dead uplink, e.g. nginx:

```nginx
location = /ping.txt { add_header Cache-Control "no-store"; }
```
