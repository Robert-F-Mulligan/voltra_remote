// Disc with 4 bolt holes (square pattern) and 3 rectangular slots (triangle pattern)
// All dimensions in mm.

disc_d       = 60.5;
thickness    = 2.5;

hole_d       = 4.5;
hole_spacing = 27.3;   // center-to-center, along each side of the square

slot_len     = 19.5;   // long side, runs tangentially (forms the triangle's sides)
slot_wid     = 9.7;    // short side, runs radially
slot_inner_r = 6.03;   // distance from disc center to the inner edge of each slot
slot_rot     = 90;     // angle of the first slot; others at +120 and +240

$fn = 128;

difference() {
    cylinder(d = disc_d, h = thickness);

    // Bolt holes
    for (x = [-1, 1], y = [-1, 1])
        translate([x * hole_spacing / 2, y * hole_spacing / 2, -1])
            cylinder(d = hole_d, h = thickness + 2);

    // Rectangular slots
    for (i = [0 : 2])
        rotate([0, 0, slot_rot + i * 120])
            translate([slot_inner_r, -slot_len / 2, -1])
                cube([slot_wid, slot_len, thickness + 2]);
}
