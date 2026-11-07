/*
 * ArdbegIME —— 轻量软键盘（ardbeg / cm-14.1）
 * ============================================================================
 *
 * 【为什么需要这个类】
 *   本 ROM（cm_ardbeg_tv）沿用 LineageOS 的 TV 产品配置
 *   vendor/cm/config/common_full_tv.mk，而该配置不含 LatinIME
 *   （只有 common_full_phone / common_mini_phone /
 *     common_full_tablet_wifionly / common_mini_tablet_wifionly 才含）。
 *   结果是系统里一个输入法都没有：
 *       # ime list -a -s
 *       （空）
 *   于是「设置 → WLAN → 选热点 → 输入密码」时点输入框弹不出键盘。
 *
 *   正规修法是在 device.mk 里把 LatinIME 加回 PRODUCT_PACKAGES
 *   （已加，见第二十一节），但要重新编译 system.img。
 *   这个类提供一个不依赖构建系统的可用键盘，先用树内预编译工具链
 *   （aapt + dx.jar + signapk.jar）打包成 APK 直接装。
 *
 * 【实现选择：为什么全部用代码搭布局，不用 XML layout】
 *   1. 键盘布局要在运行时按 Shift / 符号页切换整体重建，
 *      代码搭建比 XML + inflate 多套 layout 更直观，也少一堆文件；
 *   2. 这个 APK 是手工用 aapt 打的，少一个 layout 资源就少一处
 *      aapt 与设备端解析不一致的风险。
 *   只有 res/values/strings.xml 和 res/xml/method.xml 是必须的
 *   （前者给 IME 列表显示名字，后者是 subtype 声明）。
 *
 * 【安全】只由系统通过 BIND_INPUT_METHOD 绑定，不联网、不读存储。
 * ============================================================================
 */

package com.ardbeg.ime;

import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.inputmethodservice.InputMethodService;
import android.text.InputType;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.widget.LinearLayout;
import android.widget.TextView;

public class ArdbegIME extends InputMethodService {

    /* ================= 配色 =================
     * 本机是 TV 形态、深色界面，键盘用深灰底 + 浅色字，
     * 对比度足够又不会在暗色界面里刺眼。 */
    private static final int C_BG        = 0xFF1B1F24;   // 键盘底色
    private static final int C_KEY       = 0xFF3A424D;   // 普通键
    private static final int C_KEY_FUNC  = 0xFF2A313A;   // 功能键（Shift/Del/切页）
    private static final int C_KEY_ENTER = 0xFF2E6FF2;   // 回车键（强调色）
    private static final int C_TEXT      = 0xFFF2F4F8;   // 键面文字
    private static final int C_TEXT_DIM  = 0xFFB8C0CC;   // 功能键文字

    /* ================= 按键类型 ================= */
    private static final int T_CHAR      = 0;   // 普通字符
    private static final int T_SHIFT     = 1;   // 大小写切换
    private static final int T_DEL       = 2;   // 退格
    private static final int T_ENTER     = 3;   // 回车 / 编辑器动作
    private static final int T_SPACE     = 4;   // 空格
    private static final int T_PAGE_SYM  = 5;   // 切到符号页
    private static final int T_PAGE_SYM2 = 6;   // 切到第二符号页
    private static final int T_PAGE_ABC  = 7;   // 切回字母页

    /** 一个按键：显示文字 + 行为类型 + 相对宽度权重 */
    private static final class Key {
        final String label;
        final int type;
        final float weight;

        Key(String label, int type, float weight) {
            this.label = label;
            this.type = type;
            this.weight = weight;
        }
    }

    private static Key c(String ch)               { return new Key(ch, T_CHAR, 1f); }
    private static Key f(String lb, int t, float w) { return new Key(lb, t, w); }

    /* ================= 三套键位 ================= */

    /** 字母页（小写）。第三行两端的 Shift / 退格单独加，见 buildLetters()。 */
    private static final String[][] LETTERS = {
            {"q", "w", "e", "r", "t", "y", "u", "i", "o", "p"},
            {"a", "s", "d", "f", "g", "h", "j", "k", "l"},
            {"z", "x", "c", "v", "b", "n", "m"},
    };

    /** 符号页一：数字 + 最常用符号。WiFi 密码、账号名基本只用这一页。 */
    private static final String[][] SYMBOLS1 = {
            {"1", "2", "3", "4", "5", "6", "7", "8", "9", "0"},
            {"@", "#", "$", "%", "&", "*", "-", "_", "+", "="},
            {"!", "\"", "'", ":", ";", "/", "?", "~"},
    };

    /** 符号页二：剩下的括号、引号、斜杠之类。 */
    private static final String[][] SYMBOLS2 = {
            {"(", ")", "[", "]", "{", "}", "<", ">", "|", "\\"},
            {"^", "`", ",", ".", "€", "£", "¥", "§", "°", "·"},
            {"…", "—", "«", "»", "¿", "¡", "©", "®"},
    };

    /* ================= 运行时状态 ================= */

    /** 当前是否大写。Shift 按一次亮起，输一个字母后自动落下（与系统键盘一致）。 */
    private boolean mShift = false;

    /** 当前页：0=字母 1=符号一 2=符号二 */
    private int mPage = 0;

    private LinearLayout mRoot;
    private int mKeyHeightPx;
    private int mGapPx;

    @Override
    public void onCreate() {
        super.onCreate();
        // dp -> px。本机 density 240，1dp = 1.5px。
        float d = getResources().getDisplayMetrics().density;
        mKeyHeightPx = (int) (54 * d + 0.5f);
        mGapPx = (int) (3 * d + 0.5f);
    }

    /**
     * 强制竖屏键盘不要进入"全屏编辑"模式。
     *
     * 默认实现在屏幕较矮、或输入框所在窗口较小时会返回 true，
     * 系统会把整个输入区域做成全屏的抽取编辑器（ExtractEditText），
     * 盖住应用界面。在 TV/盒子上这会很难用，所以恒返回 false。
     */
    @Override
    public boolean onEvaluateFullscreenMode() {
        return false;
    }

    @Override
    public View onCreateInputView() {
        /*
         * 【为什么要在这里重新算一次页码】
         *   InputMethodService 的生命周期里，onStartInputView() 和
         *   onCreateInputView() 的先后顺序**不是固定的**：
         *     已经显示过键盘 -> 再次聚焦输入框：
         *         onStartInputView() 先来，此时 mRoot 已存在，rebuild() 生效
         *     键盘视图还没创建（服务刚被系统拉起）：
         *         onStartInputView() 先来，但 mRoot == null，rebuild() 直接返回，
         *         页码只存在成员变量里，等 onCreateInputView() 才真正建视图
         *
         *   如果此时成员变量里还残留着上一个输入框留下的页码（比如上次是
         *   数字框，mPage 停在符号页），建出来的键盘就会停在错误的页面上。
         *   实测就出现过「WiFi 密码框第一次弹出时停在数字符号页」。
         *
         *   所以这里用 getCurrentInputEditorInfo() 重新判定一次，保证
         *   视图创建那一刻的页码与当前输入框类型一致。
         */
        mPage = pageForEditor(getCurrentInputEditorInfo());
        mShift = false;

        mRoot = new LinearLayout(this);
        mRoot.setOrientation(LinearLayout.VERTICAL);
        mRoot.setBackgroundColor(C_BG);
        mRoot.setPadding(mGapPx, mGapPx, mGapPx, mGapPx);
        rebuild();
        return mRoot;
    }

    /**
     * 按输入框类型决定初始页：数字类输入框直接给符号页一（那里有 0-9），
     * 其余给字母页。
     *
     * 为什么不判断 TYPE_TEXT_VARIATION_PASSWORD：密码框的类型是
     * TYPE_CLASS_TEXT | TYPE_TEXT_VARIATION_PASSWORD，字母数字混合，
     * 应该从字母页开始 —— WiFi 密码绝大多数是字母开头。
     */
    private int pageForEditor(EditorInfo info) {
        if (info == null) return 0;
        int cls = info.inputType & InputType.TYPE_MASK_CLASS;
        boolean numeric = (cls == InputType.TYPE_CLASS_NUMBER)
                || (cls == InputType.TYPE_CLASS_PHONE)
                || (cls == InputType.TYPE_CLASS_DATETIME);
        return numeric ? 1 : 0;
    }

    /* ================= 布局构建 ================= */

    /** 按当前 mPage / mShift 重建整个键盘。 */
    private void rebuild() {
        if (mRoot == null) return;
        mRoot.removeAllViews();

        if (mPage == 0) {
            buildLetters();
        } else {
            buildSymbols(mPage == 1 ? SYMBOLS1 : SYMBOLS2);
        }
    }

    private void buildLetters() {
        String[][] src = LETTERS;
        for (int r = 0; r < src.length; r++) {
            String[] row = src[r];
            LinearLayout ll = newRow();
            float sideW = 1.5f;

            // 第三行左端是 Shift，右端是退格
            if (r == 2) {
                addKey(ll, f(mShift ? "⇧" : "⇧", T_SHIFT, sideW), mShift);
            }

            for (String ch : row) {
                addKey(ll, c(mShift ? ch.toUpperCase() : ch), false);
            }

            if (r == 2) {
                addKey(ll, f("⌫", T_DEL, sideW), false);
            }
            mRoot.addView(ll);
        }

        // 第四行：切符号页 / 逗号 / 空格 / 句号 / 回车
        LinearLayout last = newRow();
        addKey(last, f("?123", T_PAGE_SYM, 1.5f), false);
        addKey(last, c(","), false);
        addKey(last, f("空格", T_SPACE, 4f), false);
        addKey(last, c("."), false);
        addKey(last, f("↵", T_ENTER, 1.5f), false);
        mRoot.addView(last);
    }

    private void buildSymbols(String[][] src) {
        for (String[] row : src) {
            LinearLayout ll = newRow();
            for (String ch : row) {
                addKey(ll, c(ch), false);
            }
            mRoot.addView(ll);
        }

        LinearLayout last = newRow();
        // 第一符号页给 "=<" 去第二页，第二页给 "ABC" 回字母页
        if (mPage == 1) {
            addKey(last, f("=<", T_PAGE_SYM2, 1.5f), false);
        } else {
            addKey(last, f("ABC", T_PAGE_ABC, 1.5f), false);
        }
        addKey(last, c(","), false);
        addKey(last, f("空格", T_SPACE, 4f), false);
        addKey(last, c("."), false);
        addKey(last, f("↵", T_ENTER, 1.5f), false);
        mRoot.addView(last);
    }

    private LinearLayout newRow() {
        LinearLayout ll = new LinearLayout(this);
        ll.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, mKeyHeightPx);
        lp.bottomMargin = mGapPx;
        ll.setLayoutParams(lp);
        return ll;
    }

    /**
     * 往一行里加一个键。
     *
     * @param highlight Shift 亮起时给按键加个高亮描边，提示当前是大写状态
     */
    private void addKey(LinearLayout row, final Key key, boolean highlight) {
        TextView tv = new TextView(this);
        tv.setText(key.label);
        tv.setGravity(Gravity.CENTER);
        tv.setTextColor(key.type == T_CHAR ? C_TEXT : C_TEXT_DIM);
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, key.label.length() > 1 ? 15 : 21);
        tv.setBackground(makeKeyBg(key.type, highlight));

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.MATCH_PARENT, key.weight);
        lp.rightMargin = mGapPx;
        tv.setLayoutParams(lp);

        tv.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                onKey(key);
            }
        });

        // 空格键和回车键不需要长按重复，其余按键统一加长按连发（退格尤其需要）
        if (key.type == T_DEL) {
            tv.setOnLongClickListener(new View.OnLongClickListener() {
                @Override
                public boolean onLongClick(View v) {
                    // 长按退格：连续删 12 个字符。用 Handler 做真正的定时重复
                    // 会引入额外状态（需要在 onFinishInputView 里清理），
                    // 这里用一次性批量删除换取实现简单。
                    InputConnection ic = getCurrentInputConnection();
                    if (ic != null) {
                        ic.deleteSurroundingText(12, 0);
                    }
                    return true;
                }
            });
        }

        row.addView(tv);
    }

    private GradientDrawable makeKeyBg(int type, boolean highlight) {
        GradientDrawable g = new GradientDrawable();
        g.setCornerRadius(6 * getResources().getDisplayMetrics().density);
        int fill;
        if (type == T_ENTER) {
            fill = C_KEY_ENTER;
        } else if (type == T_CHAR) {
            fill = C_KEY;
        } else {
            fill = C_KEY_FUNC;
        }
        g.setColor(fill);
        if (highlight) {
            // Shift 亮起：加一圈亮边
            g.setStroke((int) (2 * getResources().getDisplayMetrics().density),
                    Color.WHITE);
        }
        return g;
    }

    /* ================= 按键行为 ================= */

    private void onKey(Key key) {
        InputConnection ic = getCurrentInputConnection();

        switch (key.type) {
            case T_CHAR:
                if (ic != null) {
                    ic.commitText(key.label, 1);
                }
                // 输完一个字母自动落下 Shift，与系统键盘行为一致
                if (mShift) {
                    mShift = false;
                    rebuild();
                }
                break;

            case T_SPACE:
                if (ic != null) {
                    ic.commitText(" ", 1);
                }
                break;

            case T_DEL:
                if (ic != null) {
                    // 优先按"删除选区"，没有选区时删前一个字符。
                    // 直接 deleteSurroundingText(1,0) 在部分应用（如
                    // 输入法自己没接管 combos）里删不掉已选中的文字。
                    CharSequence sel = ic.getSelectedText(0);
                    if (sel != null && sel.length() > 0) {
                        ic.commitText("", 1);
                    } else {
                        ic.deleteSurroundingText(1, 0);
                    }
                }
                break;

            case T_ENTER:
                // sendDefaultEditorAction 会按输入框的 imeOptions 走
                // 「搜索 / 发送 / 完成」等动作；没有 imeOptions 时发普通回车。
                if (ic != null) {
                    if (!sendDefaultEditorAction(true)) {
                        ic.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN,
                                KeyEvent.KEYCODE_ENTER));
                        ic.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_UP,
                                KeyEvent.KEYCODE_ENTER));
                    }
                }
                break;

            case T_SHIFT:
                mShift = !mShift;
                rebuild();
                break;

            case T_PAGE_SYM:
                mPage = 1;
                rebuild();
                break;

            case T_PAGE_SYM2:
                mPage = 2;
                rebuild();
                break;

            case T_PAGE_ABC:
                mPage = 0;
                rebuild();
                break;
        }
    }

    /**
     * 每次输入框获得焦点都会走到这里。
     *
     * 关键点：**每次都要把键盘重置回正确的起始页**。
     * 否则用户在密码框切到符号页、再切到下一个输入框，键盘还停在符号页，
     * 看起来就像"键盘坏了"。
     *
     * 页码判定与 onCreateInputView() 共用 pageForEditor()，
     * 避免两处逻辑各写一遍以后走偏。
     */
    @Override
    public void onStartInputView(EditorInfo info, boolean restarting) {
        super.onStartInputView(info, restarting);

        mShift = false;
        mPage = pageForEditor(info);
        // 若键盘视图还没建（mRoot == null），rebuild() 会安全返回，
        // 由随后的 onCreateInputView() 按同样的 mPage 建出来。
        rebuild();
    }
}
