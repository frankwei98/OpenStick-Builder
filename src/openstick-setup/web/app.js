'use strict';
(() => {
    const get = id => document.getElementById(id);
    const form = get('setup-form'), password = get('password'), confirmation = get('confirmation');
    const submit = get('submit'), reveal = get('reveal'), error = get('error'), status = get('status');
    let token = '', busy = false;
    get('ssh-command').textContent = `ssh openstick@${location.hostname}`;
    const showError = message => { error.textContent = message; error.hidden = false; };
    function success(alreadyConfigured = false) {
        password.value = ''; confirmation.value = ''; token = '';
        get('setup-view').hidden = true; get('success-view').hidden = false; status.textContent = '';
        if (alreadyConfigured) {
            get('success-title').textContent = '设备已完成设置。';
            get('success-description').textContent = '请使用已有的管理员密码登录。本次提交没有修改密码。';
        }
        document.title = 'OpenStick · 设置完成';
    }
    reveal.addEventListener('click', () => {
        const visible = password.type === 'password';
        password.type = confirmation.type = visible ? 'text' : 'password';
        reveal.textContent = visible ? '隐藏' : '显示';
        reveal.setAttribute('aria-pressed', String(visible));
        reveal.setAttribute('aria-label', visible ? '隐藏密码' : '显示密码');
    });
    async function connect() {
        try {
            const response = await fetch('/api/session', { cache: 'no-store', signal: AbortSignal.timeout(10000) });
            if (response.status === 409) { success(true); return; }
            if (!response.ok) throw new Error('unavailable');
            const data = await response.json();
            token = data.token;
            submit.disabled = false; submit.textContent = '设置管理员密码';
        } catch {
            showError('暂时无法连接设置服务。请检查 USB 连接，然后刷新页面；若仍失败，请重启设备。');
            submit.textContent = '暂时无法设置';
        }
    }
    form.addEventListener('submit', async event => {
        event.preventDefault();
        if (busy || !token) return;
        error.hidden = true;
        const length = Array.from(password.value).length;
        if (length < 12 || length > 128 || /\p{Cc}/u.test(password.value)) {
            showError('请输入 12–128 个字符的密码，不能包含控制字符。'); password.focus(); return;
        }
        if (password.value !== confirmation.value) {
            showError('两次输入的密码不一致，请检查后重试。'); confirmation.focus(); return;
        }
        busy = true; submit.disabled = true; password.disabled = confirmation.disabled = reveal.disabled = true;
        submit.textContent = '正在设置，请保持设备连接…'; status.textContent = '正在设置管理员密码。';
        let retry = false;
        try {
            const response = await fetch('/api/setup', {
                method: 'POST', headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': token },
                body: JSON.stringify({ password: password.value, confirmation: confirmation.value }),
                signal: AbortSignal.timeout(35000)
            });
            if (response.ok) { success(); return; }
            if (response.status === 409) { success(true); return; }
            if (response.status === 400) { showError('密码格式不符合要求，请检查后重新输入。'); retry = true; }
            else if (response.status === 429) { showError('提交过于频繁，请稍等片刻再试。'); retry = true; }
            else if (response.status === 403) { showError('设置会话已过期，请刷新页面后重试。'); }
            else { showError('未能确认设置结果。请重启设备，再尝试用刚才的密码登录；若设置页仍可打开，请重新设置。'); }
        } catch {
            showError('连接中断，尚未确认设置结果。请保持 USB 连接，尝试用刚才的密码登录；若失败，请重启设备后再检查设置页。');
        } finally {
            password.value = ''; confirmation.value = ''; busy = false; status.textContent = '';
            password.disabled = confirmation.disabled = reveal.disabled = false;
            submit.disabled = !retry; submit.textContent = retry ? '设置管理员密码' : '请按提示检查设备';
        }
    });
    connect();
})();
