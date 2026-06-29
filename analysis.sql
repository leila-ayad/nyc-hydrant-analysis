-- analysis_queries.sql
-- ---------------------------------------------------------------------------
-- Five progressive SQL queries for spatial analysis of NYC neighborhoods
-- and fire hydrants in PostGIS.

-- Tables used:
--   nyc_neighborhoods  (262 rows, MultiPolygon, SRID 4326)
--   nyc_hydrants       (109,725 rows, Point, SRID 4326)
--
-- Connection:
--   docker compose exec -e PGPASSWORD=gis postgis \
--     psql -h localhost -U gis -d gis
-- ---------------------------------------------------------------------------

-- What columns are in my table?
SELECT column_name 
FROM information_schema.columns 
WHERE table_name = 'nyc_neighborhoods'
ORDER BY ordinal_position;

-- Confirm SRID

SELECT ST_SRID(wkb_geometry) FROM nyc_hydrants LIMIT 1;

-- Expected: 1 Row - 4326

-- =========================================================================
-- QUERY 1: Look at the data (SELECT / FROM / WHERE)
-- =========================================================================
-- Every SQL query is a question you ask a table:
--   SELECT  → which columns do you want?
--   FROM    → which table are they in?
--   WHERE   → which rows do you want?
-- =========================================================================

-- What neighborhoods are in Manhattan?
SELECT
    ntaname,
    boroname
FROM nyc_neighborhoods
WHERE boroname = 'Manhattan'
ORDER BY ntaname;

-- Expected: 38 rows — every neighborhood in Manhattan, alphabetically


-- =========================================================================
-- QUERY 2: Use ST_Contains to match each hydrant to the neighborhood that contains it
-- =========================================================================
-- New concept: ST_Contains answers "Does polygon A fully contain polygon B?"
-- This is a spatial join. It links data from two tables based on their spatial relationship.

-- =========================================================================

-- Which neighborhood is each hydrant in?
SELECT
    n.ntaname, n.boroname
FROM nyc_neighborhoods n
JOIN nyc_hydrants h ON ST_Contains(n.wkb_geometry, h.wkb_geometry)
WHERE n.boroname = 'Manhattan'

-- Expected: 13305 rows - A table in memory with every hydrant joined to a neighborhood in Manhattan

-- =========================================================================
-- QUERY 3: Use GROUP BY to aggregate hydrant counts per neighborhood
-- New Concept: Use COUNT(*) and GROUP BY to get a table where each row is 1
--  neighborhood and there is a hydrant_count column
-- =========================================================================

SELECT
    n.ntaname, n.boroname, COUNT(*) AS hydrant_count
FROM nyc_neighborhoods n
JOIN nyc_hydrants h ON ST_Contains(n.wkb_geometry, h.wkb_geometry)
WHERE n.boroname = 'Manhattan'
GROUP BY n.ntaname, n.boroname

-- Expected: 38 Rows - Every neighborhood in Manhattan with a count of how many hydrants are in each one
--                ntaname               | boroname  | hydrant_count
-- -------------------------------------+-----------+---------------
--  Harlem (North)                      | Manhattan |           524
--  Murray Hill-Kips Bay                | Manhattan |           385
--  Midtown-Times Square                | Manhattan |           669
--  Midtown South-Flatiron-Union Square | Manhattan |           378
--  West Village                        | Manhattan |           447

-- =========================================================================
-- QUERY 4: Find hydrant density per neighborhood
-- New Concept: Find neighborhood density by transforming data from 4326 to 32118
-- =========================================================================

SELECT
    n.ntaname, n.boroname, COUNT(*) AS hydrant_count,
ROUND((ST_Area(ST_Transform(n.wkb_geometry, 32118)) / 1000000)::numeric, 2) AS area_km2,
ROUND(COUNT(*) / (ST_Area(ST_Transform(n.wkb_geometry, 32118)) / 1000000)::numeric ,2) AS hydrants_per_km2
FROM nyc_neighborhoods n
JOIN nyc_hydrants h ON ST_Contains(n.wkb_geometry, h.wkb_geometry)
WHERE n.boroname = 'Manhattan'
GROUP BY n.ntaname, n.boroname, n.wkb_geometry

-- Expected: 38 Rows - Manhattan neighborhoods with hydrant_count, area_km2 and hydrant_density_km2

--           ntaname                | boroname  | hydrant_count | area_km2 | hydrants_per_km2
-- --------------------------------+-----------+---------------+----------+------------------
--  Central Park                   | Manhattan |            63 |     3.56 |             17.7
--  Inwood Hill Park               | Manhattan |            14 |     0.93 |            15.06
--  Highbridge Park                | Manhattan |            32 |     0.72 |            44.42
--  United Nations                 | Manhattan |            17 |     0.10 |           167.68
--  East Harlem (North)            | Manhattan |           583 |     2.43 |           240.26

-- =========================================================================
-- QUERY 5: Compute the percent of each neighborhood within 100 meters of a hydrant (coverage analysis).
-- New Concept(s): Buffer + Union + Intersection
-- Buffer draws a  100m circle around each hydrant
-- Union dissolves all the overlapping circles into a single shape per neighborhood
-- Intersection cuts the merged buffer shape down to only the part that falls inside the neighborhood polygon
-- 
-- =========================================================================

WITH coverage AS (
    SELECT
        n.ntaname,
        n.boroname,
        n.wkb_geometry AS nbhd_geom,
        ST_Union(ST_Buffer(h.wkb_geometry::geography, 100)::geometry) AS covered_geom
    FROM nyc_neighborhoods n
    JOIN nyc_hydrants h ON ST_Contains(n.wkb_geometry, h.wkb_geometry)
    WHERE n.boroname = 'Manhattan'
    GROUP BY n.ntaname, n.boroname, n.wkb_geometry
)

SELECT
    ntaname,
    boroname,
    ROUND(
        (ST_Area(ST_Intersection(covered_geom, nbhd_geom)::geography) /
         ST_Area(nbhd_geom::geography) * 100)::numeric
    , 1) AS pct_covered
FROM coverage
ORDER BY pct_covered DESC;

--                ntaname               | boroname  | pct_covered
-- -------------------------------------+-----------+-------------
--  Midtown-Times Square                | Manhattan |       100.0
--  Midtown South-Flatiron-Union Square | Manhattan |        99.9
--  East Harlem (South)                 | Manhattan |        99.8
--  Chinatown-Two Bridges               | Manhattan |        99.5
--  SoHo-Little Italy-Hudson Square     | Manhattan |        99.1



learnings: 

Every column in select that isn't in an aggregate function must be listed in GROUP BY
Differenc between casting to geography and ST_Transform =Both give you accurate real-world measurements, but they work differently:

Casting to geography (::geography)

Keeps your coordinates as-is (still lat/lon)
PostGIS does the math on a sphere/ellipsoid model of Earth
No permanent change to the data, just changes how PostGIS calculates
Simpler, but slightly slower for complex shapes
Transforming (ST_Transform)

Actually converts the coordinates to a different CRS (e.g. 32118)
The new coordinates are in meters on a flat plane
ST_Area then does simple flat 2D math — fast and straightforward
More control over which projection you use (important if accuracy for a specific region matters)

CTE - common table expression - a named temp result set that I define at the top of a query then use as a table in a separate query below it (WITH coverage AS ) 