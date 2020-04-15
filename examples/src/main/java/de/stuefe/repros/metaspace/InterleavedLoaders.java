package de.stuefe.repros.metaspace;

import de.stuefe.repros.metaspace.internals.InMemoryClassLoader;
import de.stuefe.repros.metaspace.internals.Utils;
import picocli.CommandLine;

import java.io.IOException;
import java.util.ArrayList;
import java.util.concurrent.Callable;

/**
 * This test will create an artificial Metaspace usage spike by letting multiple loaders load
 * classes. It then collects those loaders and classes to measure how Metaspace recovers from
 * a temporary spike. It repeats this once.
 *
 * The loaders are loading classes in an interleaved fashion to trigger some amount of
 * Metaspace fragmentation.
 *
 * Use with --auto-yes to automatically confirm key presses and execute the whole
 * test in unattended mode. Good to collect usage curves.
 *
 * Use with both --auto-yes and --nowait to remove all waits from the code, to measure
 * performance.
 *
 * See also: ParallelLoaders, which does the same test from multiple threads.
 *
 */

@CommandLine.Command(name = "InterleavedLoaders", mixinStandardHelpOptions = true,
        description = "InterleavedLoaders repro.")
public class InterleavedLoaders implements Callable<Integer> {

    public static void main(String... args) {
        int exitCode = new CommandLine(new InterleavedLoaders()).execute(args);
        System.exit(exitCode);
    }

    private static String nameClass(int number) {
        return "myclass_" + number;
    }

    private static void generateClasses(int num, int sizeFactor, float wiggle) {
        for (int j = 0; j < num; j++) {
            String className = nameClass(j);
            Utils.createRandomClass(className, sizeFactor, wiggle);
            if (j % 100 == 0) {
                System.out.print("*");
            }
        }
        System.out.println(".");
    }

    @CommandLine.Option(names = { "--num-clusters" }, defaultValue = "5",
            description = "Number of loader clusters.")
    int num_clusters;

    @CommandLine.Option(names = { "--num-loaders" }, defaultValue = "80",
            description = "Number of loaders per cluster.")
    int num_loaders_per_cluster;

    @CommandLine.Option(names = { "--num-classes" }, defaultValue = "100",
            description = "Number of classes per loader.")
    int num_classes_per_loader;

    @CommandLine.Option(names = { "--class-size" }, defaultValue = "10",
            description = "Class size factor.")
    int class_size_factor;

    @CommandLine.Option(names = { "--auto-yes", "-y" }, defaultValue = "false",
            description = "Autoyes.")
    boolean auto_yes;

    @CommandLine.Option(names = { "--nowait" }, defaultValue = "false",
            description = "do not wait (only with autoyes).")
    boolean nowait;

    @CommandLine.Option(names = { "--wiggle" }, defaultValue = "0.0",
            description = "Wiggle factor (0.0 .. 1.0f, default 0,0f).")
    float wiggle = 0;

    int unattendedModeWaitSecs = 4;


    void waitForKeyPress(String message, int secs) {
        if (message != null) {
            System.out.println(message);
        }
        System.out.print("<press key>");
        if (auto_yes) {
            System.out.print (" ... (auto-yes) ");
            if (secs > 0 && nowait == false) {
                System.out.print("... waiting " +secs + " secs ...");
                try {
                    Thread.sleep(secs * 1000);
                } catch (InterruptedException e) {
                }
            }
        } else {
            try {
                System.in.read();
            } catch (IOException e) {
                e.printStackTrace();
            }
        }
        System.out.println (" ... continuing.");
    }

    void waitForKeyPress(String message) { waitForKeyPress(message, unattendedModeWaitSecs); }

    class LoaderGeneration {
        ArrayList<ClassLoader> loaders = new ArrayList<>();
        ArrayList<Class> loaded_classes = new ArrayList<>();
    }

    private void loadInterleavedLoaders(LoaderGeneration[] generations, int numGenerations,
                                        int numLoadersPerGeneration, int numClassesPerLoader) throws ClassNotFoundException {
        int numLoadersTotal = numLoadersPerGeneration * numGenerations;
        for (int nloader = 0; nloader < numLoadersTotal; nloader++) {
            ClassLoader loader = new InMemoryClassLoader("myloader", null);
            int gen = nloader % numGenerations;
            generations[gen].loaders.add(loader);
            for (int nclass = 0; nclass < numClassesPerLoader; nclass++) {
                // Let it load all classes
                Class<?> clazz = Class.forName(nameClass(nclass), true, loader);
                generations[gen].loaded_classes.add(clazz);
            }
            if (nloader % (numLoadersTotal / 20) == 0) {
                System.out.print("*");
            }
        }
        System.gc();
        System.gc();
        System.out.println(".");
    }


    @Override
    public Integer call() throws Exception {

        System.out.println("Loader gens: " + num_clusters + ".");
        System.out.println("Loaders per gen: " + num_loaders_per_cluster + ".");
        System.out.println("Classes per loader: " + num_classes_per_loader + ".");
        System.out.println("Class size: " + class_size_factor + ".");
        System.out.println("Wiggle factor: " + wiggle + ".");

        generateClasses(num_classes_per_loader, class_size_factor, wiggle);

        LoaderGeneration[] generations = new LoaderGeneration[num_clusters];
        for (int i = 0; i < num_clusters; i++) {
            generations[i] = new LoaderGeneration();
        }
        System.gc();
        System.gc();

        long start = System.currentTimeMillis();

        waitForKeyPress("Will load " + num_clusters +
                " generations of " + num_loaders_per_cluster + " loaders each, "
                + " each loader loading " + num_classes_per_loader + " classes...", 4);

        // First spike
        loadInterleavedLoaders(generations, num_clusters, num_loaders_per_cluster, num_classes_per_loader);

        waitForKeyPress("After loading...");

        // get rid of all but the last two
        for (int i = num_clusters - 1; i >= 1; i--) {
            waitForKeyPress("Before freeing generation " + i + "...");
            generations[i].loaders.clear();
            generations[i].loaded_classes.clear();
            System.gc();
            System.gc();
            waitForKeyPress("After freeing generation " + i + ".");
        }

        waitForKeyPress(null, 60);

        // Second spike
        loadInterleavedLoaders(generations, num_clusters, num_loaders_per_cluster, num_classes_per_loader);

        waitForKeyPress("After loading.");

        // Now free all
        for (int i = num_clusters - 1; i >= 0; i--) {
            waitForKeyPress("Before freeing generation " + i + "...");
            generations[i].loaders.clear();
            generations[i].loaded_classes.clear();
            System.gc();
            System.gc();
            waitForKeyPress("After freeing generation " + i + ".");
        }

        long finish = System.currentTimeMillis();
        long timeElapsed = finish - start;
        System.out.println("Elapsed Time: " + timeElapsed + " ms");

        return 0;
    }

}
