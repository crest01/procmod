local S = terralib.require("qs.lib.std")
local gl = terralib.require("gl.gl")
local Vec = terralib.require("linalg.vec")
local Mat = terralib.require("linalg.mat")
local BBox = terralib.require("geometry.bbox")
local BinaryGrid = terralib.require("geometry.binaryGrid3d")
local Intersections = terralib.require("geometry.intersection")


-- Super simple mesh struct that can accumulate geometry and draw itself

local Mesh = S.memoize(function(real)

	assert(real == float or real == double,
		"Mesh: real must be float or double")

	local Vec3 = Vec(real, 3)
	local Mat4 = Mat(real, 4, 4)
	local BBox3 = BBox(Vec3)
	local Vec2 = Vec(real, 2)
	local Intersection = Intersections(real)

	local glVertex = real == float and gl.glVertex3fv or gl.glVertex3dv
	local glNormal = real == float and gl.glNormal3fv or gl.glNormal3dv

	local struct Index { vertex: uint, normal: uint }

	local struct Mesh(S.Object)
	{
		vertices: S.Vector(Vec3),
		normals: S.Vector(Vec3),
		indices: S.Vector(Index)
	}

	terra Mesh:numVertices() return self.vertices:size() end
	terra Mesh:numNormals() return self.normals:size() end
	terra Mesh:numIndices() return self.indices:size() end
	terra Mesh:numTris() return self:numIndices()/3 end

	Mesh.methods.getVertex = macro(function(self, i) return `self.vertices(i) end)
	Mesh.methods.getNormal = macro(function(self, i) return `self.normals(i) end)
	Mesh.methods.getIndex = macro(function(self, i) return `self.indices(i) end)

	terra Mesh:addVertex(vert: Vec3) self.vertices:insert(vert) end
	terra Mesh:addNormal(norm: Vec3) self.normals:insert(norm) end
	terra Mesh:addIndex(vind: uint, nind: uint) self.indices:insert(Index{vind,nind}) end

	terra Mesh:draw()
		-- Just simple immediate mode drawing for now
		gl.glBegin(gl.GL_TRIANGLES)
		for i in self.indices do
			glNormal(&(self.normals(i.normal).entries[0]))
			glVertex(&(self.vertices(i.vertex).entries[0]))
		end
		gl.glEnd()
	end

	terra Mesh:clear()
		self.vertices:clear()
		self.normals:clear()
		self.indices:clear()
	end

	terra Mesh:append(other: &Mesh)
		var nverts = self.vertices:size()
		var nnorms = self.normals:size()
		for ov in other.vertices do
			self:addVertex(ov)
		end
		for on in other.normals do
			self:addNormal(on)
		end
		for oi in other.indices do
			self:addIndex(oi.vertex + nverts, oi.normal + nnorms)
		end
	end

	terra Mesh:transform(xform: &Mat4)
		for i=0,self.vertices:size() do
			self.vertices(i) = xform:transformPoint(self.vertices(i))
		end
		-- TODO: Implement 4x4 matrix inversion and use the inverse transpose
		--    for the normals (I expect to only use rotations and uniform scales
		--    for the time being, so this should be fine for now).
		for i=0,self.normals:size() do
			self.normals(i) = xform:transformVector(self.normals(i))
		end
	end

	terra Mesh:bbox()
		var bbox : BBox3
		bbox:init()
		for v in self.vertices do
			bbox:expand(v)
		end
		return bbox
	end

	-- Check if there is an intersection between self and other
	-- Contracts both of the triangles by a tiny epsilon so that touching (but not interpentratring)
	--    faces are not considered intersecting.
	local contractTri = macro(function(v0, v1, v2)
		local CONTRACT_EPS = 1e-10
		return quote
			var centroid = (v0 + v1 + v2) / 3.0
			v0 = v0 - (v0 - centroid)*CONTRACT_EPS
			v1 = v1 - (v1 - centroid)*CONTRACT_EPS
			v2 = v2 - (v2 - centroid)*CONTRACT_EPS
		end
	end)
	local FUDGE_FACTOR = 1e-10
	terra Mesh:intersects(other: &Mesh) : bool
		-- First, check that the overall bboxes of the two meshes actually intersect
		var selfbbox = self:bbox()
		var otherbbox = other:bbox()
		if not selfbbox:intersects(&otherbbox) then
			return false
		end
		-- Now, for every triangle in self, see if other intersects with it (checking overall bbox first)
		-- We loop over the triangles backwards, because a frequent use case is intersecting an in-construction mesh with
		--    a new component about to be added to it. Triangles toward the end of the list were added later, and are
		--    thus likely to be closer to the mesh we're testing again. Intersections are more likely between closer things,
		--    which will cause us to bail out of this function sooner and save time.
		var numSelfTris = int(self:numTris())
		var numOtherTris = int(other:numTris())
		for j=numSelfTris-1,-1,-1 do
			var u0 = self.vertices(self.indices(3*j).vertex)
			var u1 = self.vertices(self.indices(3*j + 1).vertex)
			var u2 = self.vertices(self.indices(3*j + 2).vertex)
			contractTri(u0, u1, u2)
			var selftribbox = BBox3.salloc():init()
			selftribbox:expand(u0); selftribbox:expand(u1); selftribbox:expand(u2)
			if selftribbox:intersects(&otherbbox) then
				for i=0,numOtherTris do
					var v0 = other.vertices(other.indices(3*i).vertex)
					var v1 = other.vertices(other.indices(3*i + 1).vertex)
					var v2 = other.vertices(other.indices(3*i + 2).vertex)
					contractTri(v0, v1, v2)
					var othertribbox = BBox3.salloc():init()
					othertribbox:expand(v0); othertribbox:expand(v1); othertribbox:expand(v2)
					if selftribbox:intersects(othertribbox) then
						if Intersection.intersectTriangleTriangle(u0, u1, u2, v0, v1, v2, false, FUDGE_FACTOR) then
							return true
						end	
					end
				end
			end
		end
		return false
	end

	terra Mesh:selfIntersects()
		return self:intersects(self)
	end

	-- We loop over the meshes in reverse order, for the same reason as above
	terra Mesh:intersects(meshes: &S.Vector(Mesh)) :  bool
		var numMeshes = int64(meshes:size())
		for i=numMeshes-1,-1,-1 do
			if self:intersects(meshes:get(i)) then
				return true
			end
		end
		return false
	end

	-- Find all triangles involved in intersection, store them in another mesh
	terra Mesh:findAllIntersectingTris(other: &Mesh, outmesh: &Mesh) : bool
		-- First, check that the overall bboxes of the two meshes actually intersect
		var selfbbox = self:bbox()
		var otherbbox = other:bbox()
		if not selfbbox:intersects(&otherbbox) then
			return false
		end 
		-- Now, for every triangle in self, see if other intersects with it (checking overall bbox first)
		var hasIntersections = false
		var numSelfTris = int(self:numTris())
		var numOtherTris = int(other:numTris())
		for j=numSelfTris-1,-1,-1 do
			var u0 = self.vertices(self.indices(3*j).vertex)
			var u1 = self.vertices(self.indices(3*j + 1).vertex)
			var u2 = self.vertices(self.indices(3*j + 2).vertex)
			contractTri(u0, u1, u2)
			var selftribbox = BBox3.salloc():init()
			selftribbox:expand(u0); selftribbox:expand(u1); selftribbox:expand(u2)
			if selftribbox:intersects(&otherbbox) then
				for i=0,numOtherTris do
					var v0 = other.vertices(other.indices(3*i).vertex)
					var v1 = other.vertices(other.indices(3*i + 1).vertex)
					var v2 = other.vertices(other.indices(3*i + 2).vertex)
					contractTri(v0, v1, v2)
					var othertribbox = BBox3.salloc():init()
					othertribbox:expand(v0); othertribbox:expand(v1); othertribbox:expand(v2)
					if selftribbox:intersects(othertribbox) then
						if Intersection.intersectTriangleTriangle(u0, u1, u2, v0, v1, v2, false, FUDGE_FACTOR) then
							hasIntersections = true
							var bvi = outmesh:numVertices()
							var bni = outmesh:numNormals()
							outmesh:addVertex(u0); outmesh:addVertex(u1); outmesh:addVertex(u2)
							var n = (u1 - u0):cross(u2 - u0); n:normalize()
							outmesh:addNormal(n)
							outmesh:addIndex(bvi, bni); outmesh:addIndex(bvi+1, bni); outmesh:addIndex(bvi+2, bni)
							bvi = outmesh:numVertices()
							bni = outmesh:numNormals()
							outmesh:addVertex(v0); outmesh:addVertex(v1); outmesh:addVertex(v2)
							n = (v1 - v0):cross(v2 - v0); n:normalize()
							outmesh:addNormal(n)
							outmesh:addIndex(bvi, bni); outmesh:addIndex(bvi+1, bni); outmesh:addIndex(bvi+2, bni)
						end	
					end
				end
			end
		end
		return hasIntersections
	end

	terra Mesh:findAllSelfIntersectingTris(outmesh: &Mesh) : bool
		return self:findAllIntersectingTris(self, outmesh)
	end

	-- Returns a bounding box of the voxels touched by this triangle
	local Vec3u = Vec(uint, 3)
	local BBox3u = BBox(Vec3u)
	local terra voxelizeTriangle(outgrid: &BinaryGrid, v0: Vec3, v1: Vec3, v2: Vec3, solid: bool)
		var tribb = BBox3.salloc():init()
		tribb:expand(v0); tribb:expand(v1); tribb:expand(v2)
		-- If a triangle is perfectly axis-aligned, it will 'span' zero voxels, so the loops below
		--    will do nothing. To get around this, we expand the bbox a little bit.
		tribb:expand(0.000001)
		var minI = tribb.mins:floor()
		var maxI = tribb.maxs:ceil()
		var bb = BBox3u.salloc():init(Vec3u.create(minI(0), minI(1), minI(2)),
									  Vec3u.create(maxI(0), maxI(1), maxI(2)))
		-- Take care to ensure that we don't loop over any voxels that are outside the actual grid.
		bb.maxs:minInPlace(Vec3u.create(outgrid.cols, outgrid.rows, outgrid.slices))
		for k=bb.mins(2),bb.maxs(2) do
			for i=bb.mins(1),bb.maxs(1) do
				for j=bb.mins(0),bb.maxs(0) do
					var v = Vec3.create(real(j), real(i), real(k))
					var voxel = BBox3.salloc():init(
						v,
						v + Vec3.create(1.0)
					)
					-- Triangle has to intersect the voxel
					if voxel:intersects(v0, v1, v2) then
						outgrid:setVoxel(i,j,k)
					end
				end
			end
		end
		return @bb
	end

	-- Returns the number of triangles that fell outside the bounds
	terra Mesh:voxelize(outgrid: &BinaryGrid, bounds: &BBox3, xres: uint, yres: uint, zres: uint, solid: bool) : uint
		outgrid:resize(yres, xres, zres)
		var extents = bounds:extents()
		var xsize = extents(0)/xres
		var ysize = extents(1)/yres
		var zsize = extents(2)/zres
		var worldtovox = Mat4.scale(1.0/xsize, 1.0/ysize, 1.0/zsize) * Mat4.translate(-bounds.mins)
		var numtris = self.indices:size() / 3
		var gridbounds = BBox3.salloc():init(
			Vec3.create(0.0),
			Vec3.create(real(outgrid.cols), real(outgrid.rows), real(outgrid.slices))
		)
		var numOutsideTris = 0
		var touchedbb = BBox3u.salloc():init()
		for i=0,numtris do
			var p0 = worldtovox:transformPoint(self.vertices(self.indices(3*i).vertex))
			var p1 = worldtovox:transformPoint(self.vertices(self.indices(3*i + 1).vertex))
			var p2 = worldtovox:transformPoint(self.vertices(self.indices(3*i + 2).vertex))
			var tribb = BBox3.salloc():init()
			tribb:expand(p0); tribb:expand(p1); tribb:expand(p2)
			if tribb:intersects(gridbounds) then
				var bb = voxelizeTriangle(outgrid, p0, p1, p2, solid)
				touchedbb:unionWith(&bb)
			else
				numOutsideTris = numOutsideTris + 1
			end
		end
		if solid then
			outgrid:fillInterior(touchedbb)
		end
		return numOutsideTris
	end

	-- Find xres,yres,zres given a target voxel size
	terra Mesh:voxelize(outgrid: &BinaryGrid, bounds: &BBox3, voxelSize: real, solid: bool) : uint
		var numvox = (bounds:extents() / voxelSize):ceil()
		return self:voxelize(outgrid, bounds, uint(numvox(0)), uint(numvox(1)), uint(numvox(2)), solid)
	end

	-- Use mesh's bounding box as bounds for voxelization
	terra Mesh:voxelize(outgrid: &BinaryGrid, xres: uint, yres: uint, zres: uint, solid: bool) : uint
		var bounds = self:bbox()
		return self:voxelize(outgrid, &bounds, xres, yres, zres, solid)
	end
	terra Mesh:voxelize(outgrid: &BinaryGrid, voxelSize: real, solid: bool) : uint
		var bounds = self:bbox()
		return self:voxelize(outgrid, &bounds, voxelSize, solid)
	end

	-- Super simple: only handles triangular faces, doesn't handle UVs.
	-- f directives are assumed to be of the form vi//ni (i.e. requires normals).
	local C = terralib.includec("string.h")
	local delim = " /\n"
	terra Mesh:loadOBJ(filename: rawstring)
		var f = S.fopen(filename, "r")
		if f == nil then
			S.printf("Mesh:loadOBJ - could not open file '%s'\n", filename)
			S.assert(false)
		end
		var line : int8[1024]
		var numlines = 0
		while S.fgets(line, 1024, f) ~= nil do
			var cmd = C.strtok(line, delim)
			-- Skip empty lines and lines starting with #
			if cmd ~= nil and C.strcmp(cmd, "#") ~= 0 then
				if C.strcmp(cmd, "f") == 0 then
					var vi = S.atoi(C.strtok(nil, delim)) - 1
					var ni = S.atoi(C.strtok(nil, delim)) - 1
					self:addIndex(vi, ni)
					vi = S.atoi(C.strtok(nil, delim)) - 1
					ni = S.atoi(C.strtok(nil, delim)) - 1
					self:addIndex(vi, ni)
					vi = S.atoi(C.strtok(nil, delim)) - 1 
					ni = S.atoi(C.strtok(nil, delim)) - 1
					self:addIndex(vi, ni)
				elseif C.strcmp(cmd, "v") == 0 then
					var x = S.atof(C.strtok(nil, delim))
					var y = S.atof(C.strtok(nil, delim))
					var z = S.atof(C.strtok(nil, delim))
					self:addVertex(Vec3.create(x,y,z))
				elseif C.strcmp(cmd, "vn") == 0 then
					var x = S.atof(C.strtok(nil, delim))
					var y = S.atof(C.strtok(nil, delim))
					var z = S.atof(C.strtok(nil, delim))
					self:addNormal(Vec3.create(x,y,z))
				end
			end
		end
		S.fclose(f)
	end

	return Mesh

end)

return Mesh


