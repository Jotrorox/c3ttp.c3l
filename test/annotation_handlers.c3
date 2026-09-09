module annotation_handlers;
import c3ttp;

fn String greeting() @Route({ GET, "/imported" }) => "imported";
