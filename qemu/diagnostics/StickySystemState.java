/*
 * QEMU-only diagnostic helper: replace the sticky TomTom system-state intent.
 * AndroidAutoFullScreenActivity accepts states 5 and 13. This is not needed on
 * the physical car, whose SystemStateManager publishes the real vehicle state.
 *
 * Build on the host:
 *   javac -source 8 -target 8 -bootclasspath "$ANDROID_JAR" \
 *     -d classes diagnostics/StickySystemState.java
 *   d8 --min-api 8 --output dex classes/StickySystemState.class
 *   (cd dex && jar cf sticky-system-state.jar classes.dex)
 *
 * Run in the Froyo guest after transferring the jar:
 *   CLASSPATH=/data/local/tmp/sticky-system-state.jar \
 *     app_process /system/bin StickySystemState 5
 */
import android.content.Intent;
import java.lang.reflect.Method;

public final class StickySystemState {
    private static final String ACTION =
            "com.tomtom.intent.action.SYSTEM_STATE_CHANGED";
    private static final String EXTRA =
            "com.tomtom.intent.extra.SYSTEM_STATE";

    public static void main(String[] args) throws Exception {
        int state = args.length == 0 ? 5 : Integer.parseInt(args[0]);
        Class<?> activityManagerNative =
                Class.forName("android.app.ActivityManagerNative");
        Method getDefault = activityManagerNative.getDeclaredMethod("getDefault");
        getDefault.setAccessible(true);
        Object manager = getDefault.invoke(null);

        Method broadcastIntent = null;
        for (Method method : manager.getClass().getMethods()) {
            if (method.getName().equals("broadcastIntent")) {
                broadcastIntent = method;
                break;
            }
        }
        if (broadcastIntent == null) {
            throw new NoSuchMethodException("broadcastIntent");
        }

        broadcastIntent.setAccessible(true);
        Class<?>[] types = broadcastIntent.getParameterTypes();
        Object[] values = new Object[types.length];
        Intent update = new Intent(ACTION).putExtra(EXTRA, state);
        boolean usedIntent = false;
        for (int i = 0; i < types.length; i++) {
            if (types[i] == Intent.class && !usedIntent) {
                values[i] = update;
                usedIntent = true;
            } else if (types[i] == Integer.TYPE) {
                values[i] = Integer.valueOf(0);
            } else if (types[i] == Boolean.TYPE) {
                // Froyo's final argument is the sticky flag.
                values[i] = Boolean.valueOf(i == types.length - 1);
            } else {
                values[i] = null;
            }
        }
        Object result = broadcastIntent.invoke(manager, values);
        System.out.println("state=" + state + " sticky broadcast result="
                + result + " args=" + types.length);
    }
}
