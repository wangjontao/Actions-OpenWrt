"""Exercise the compact FastACL 2.5.6 UI against an isolated demo backend."""
import pathlib, re, threading, traceback
from http.server import ThreadingHTTPServer
from playwright.sync_api import sync_playwright, expect
import preview_server

OUT=pathlib.Path(__file__).parents[1]/'test-results'
OUT.mkdir(parents=True,exist_ok=True)
server=ThreadingHTTPServer(('127.0.0.1',0),preview_server.Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
url=f'http://127.0.0.1:{server.server_port}'
stage='startup';page=None;errors=[]
try:
    with sync_playwright() as p:
        browser=p.chromium.launch();page=browser.new_page(viewport={'width':1440,'height':1080})
        page.on('pageerror',lambda e:errors.append(str(e)))

        stage='initial load';page.goto(url)
        expect(page.get_by_text('FastACL 2.5.6',exact=False)).to_be_visible()
        expect(page.locator('#f25-devices .item')).to_have_count(3)
        expect(page.get_by_role('heading',name='多 WiFi 分配模式',exact=True)).to_be_visible()
        expect(page.locator('#f25-direct-dns')).to_have_value('alidns')
        expect(page.locator('#f25-proxy-dns')).to_have_value('cloudflare')

        stage='device counters and label-only save'
        expect(page.locator('#f25-stat-total')).to_have_text('3')
        expect(page.locator('#f25-stat-online')).to_have_text('2')
        expect(page.locator('.device-online.is-online')).to_have_count(2)
        expect(page.locator('.device-online.is-offline')).to_have_count(1)
        device=page.locator('#f25-devices .item').nth(1)
        device.get_by_role('textbox').first.fill('办公室手机')
        device.get_by_role('button',name='保存备注',exact=True).click()
        expect(device.locator('.device-title')).to_contain_text('办公室手机')
        device.get_by_role('textbox').first.fill('手机 B')
        device.get_by_role('button',name='保存备注',exact=True).click()
        expect(device.locator('.device-title')).to_contain_text('手机 B')
        stage='node rename retains ordering'
        page.once('dialog',lambda d:d.accept('Renamed first node'))
        page.locator('.node-row').first.get_by_role('button',name='重命名',exact=True).click()
        expect(page.locator('.node-row').first.locator('.title')).to_have_text('Renamed first node')

        stage='numbered subscription list'
        subscription=page.locator('#f25-sub-name').locator('xpath=ancestor::details[1]')
        subscription.locator(':scope > summary').click()
        expect(page.locator('#f25-sub-name')).to_be_visible()
        page.locator('#f25-sub-name').fill('测试机场')
        page.locator('#f25-sub-url').fill('https://subscription.example.invalid/list')
        page.get_by_role('button',name='添加订阅',exact=True).click()
        expect(page.locator('.subscription-row')).to_have_count(1)
        expect(page.locator('.subscription-row .subscription-number')).to_have_text('01')
        expect(page.locator('.subscription-row .subscription-identity')).to_contain_text('测试机场')
        expect(page.locator('.subscription-row .subscription-update')).to_have_text('更新')
        expect(page.locator('#f25-sub-update')).to_have_class(re.compile(r'\bsubscription-update\b'))

        stage='wireless stations and sampled rates'
        expect(page.locator('#f25-wireless-list')).to_have_count(0)
        page.goto(url+'/wireless')
        expect(page.locator('#f25-wireless-list')).to_contain_text('手机 A')
        expect(page.locator('#f25-wireless-list')).to_contain_text('192.168.7.101')
        expect(page.locator('#f25-wireless-list')).to_contain_text('0.80 Mbps',timeout=10000)
        page.set_viewport_size({'width':390,'height':844})
        assert page.evaluate('document.documentElement.scrollWidth <= innerWidth')
        page.set_viewport_size({'width':1440,'height':1080})
        page.goto(url)
        stage='node exit probe'
        page.locator('.node-row').first.get_by_role('button',name='检测出口',exact=True).click()
        expect(page.locator('.node-row').first.locator('.probe-result')).to_contain_text('203.0.113.9')
        stage='collapse persistence'
        node_section=page.locator('#f25-node-list').locator('xpath=ancestor::details[1]')
        node_section.locator('summary').click()
        expect(page.locator('#f25-node-list')).not_to_be_visible()
        node_section.locator('summary').click()
        stage='global DNS hot save' 
        page.locator('#f25-proxy-dns').select_option('google')
        page.get_by_role('button',name='保存 DNS',exact=True).click()
        expect(page.get_by_role('status')).to_contain_text('应用层快速切换完成',timeout=10000)

        stage='main device quick assignment'
        page.locator('#f25-node-list .item').first.get_by_role('button',name='分配',exact=True).click()
        expect(page.get_by_text('快速分配节点',exact=True)).to_be_visible()
        page.locator('#f25-assign-type').select_option('device')
        page.locator('#f25-assign-target').select_option('02:00:00:00:00:02')
        page.locator('#f25-assign-go').click()
        expect(page.get_by_role('status')).to_contain_text('应用层快速切换完成',timeout=10000)
        expect(page.locator('#f25-assign-modal')).to_have_class(re.compile(r'\bhidden\b'))

        stage='node import'
        page.get_by_role('button',name='+ 导入节点',exact=True).click()
        page.locator('#f25-links').fill('socks5://user:pass@proxy.example:1080#US\nproxy2.example:1080:user:pass')
        page.get_by_role('button',name='导入',exact=True).click()
        expect(page.get_by_role('status')).to_contain_text('成功导入 2 个节点',timeout=10000)

        stage='WiFi topology create'
        page.locator('#f25-wifi-create-panel > summary').click()
        page.locator('#f25-w5').fill('1');page.locator('#f25-w2').fill('1');page.locator('#f25-wprefix').fill('AP')
        page.get_by_role('button',name='批量建立 WiFi',exact=True).click()
        expect(page.get_by_role('status')).to_contain_text('WiFi 拓扑已保存',timeout=10000)
        expect(page.locator('#f25-wifis .item')).to_have_count(2)

        stage='managed WiFi quick assignment'
        page.locator('#f25-node-list .item').nth(1).get_by_role('button',name='分配',exact=True).click()
        page.locator('#f25-assign-type').select_option('wifi')
        page.locator('#f25-assign-target').select_option('jfa25w01')
        page.locator('#f25-assign-go').click()
        expect(page.get_by_role('status')).to_contain_text('应用层快速切换',timeout=10000)

        stage='protected batch deletion'
        page.locator('#f25-select-all').click()
        page.once('dialog',lambda d:d.accept())
        page.locator('#f25-delete-selected').click()
        expect(page.get_by_role('status')).to_contain_text('跳过',timeout=10000)

        stage='search and responsive screenshots'
        page.locator('#f25-search').fill('手机 B')
        expect(page.locator('#f25-devices .item')).to_have_count(1)
        page.locator('#f25-search').fill('')
        page.screenshot(path=str(OUT/'ui-desktop-lite.png'),full_page=True)
        page.set_viewport_size({'width':390,'height':844})
        expect(page.get_by_text('全局 DNS',exact=True)).to_be_visible()
        page.screenshot(path=str(OUT/'ui-mobile-lite.png'),full_page=True)
        assert not errors,errors
        browser.close();print('FastACL 2.5.6 quick-switch, batch-delete and responsive UI passed')
except Exception:
    detail='stage: '+stage+'\n\n'+traceback.format_exc()+'\npage errors:\n'+'\n'.join(errors)
    (OUT/'ui-browser-error.txt').write_text(detail,encoding='utf-8')
    if page is not None:
        try: page.screenshot(path=str(OUT/'ui-browser-failure.png'),full_page=True)
        except Exception: pass
    print(detail)
    raise
finally:
    server.shutdown();server.server_close()
