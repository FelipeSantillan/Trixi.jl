# This file contains functions that are related to the AMR capabilities of the DG solver

# Refine elements in the DG solver based on a list of cell_ids that should be refined
function Solvers.refine!(dg::Dg{Eqn, V, N}, mesh::TreeMesh,
                         cells_to_refine::AbstractArray{Int}) where {Eqn, V, N}
  # Return early if there is nothing to do
  if isempty(cells_to_refine)
    return
  end

  # Determine for each existing element whether it needs to be refined
  needs_refinement = falses(nelements(dg.elements))
  tree = mesh.tree
  # The "Ref(...)" is such that we can vectorize the search but not the array that is searched
  elements_to_refine = searchsortedfirst.(Ref(dg.elements.cell_ids[1:nelements(dg.elements)]),
                                          cells_to_refine)
  needs_refinement[elements_to_refine] .= true

  # Retain current solution data
  old_n_elements = nelements(dg.elements)
  old_u = dg.elements.u

  # Get new list of leaf cells
  leaf_cell_ids = leaf_cells(tree)

  # Initialize new elements container
  elements = init_elements(leaf_cell_ids, mesh, Val(V), Val(N))
  n_elements = nelements(elements)

  # Loop over all elements in old container and either copy them or refine them
  element_id = 1
  for old_element_id in 1:old_n_elements
    if needs_refinement[old_element_id]
      # Refine element and store solution directly in new data structure
      refine_element!(elements.u, element_id, old_u, old_element_id, dg,
                      dg.mortar_forward_upper, dg.mortar_forward_lower)
      element_id += 2^ndim
    else
      # Copy old element data to new element container
      @views elements.u[:, :, :, element_id] .= old_u[:, :, :, old_element_id]
      element_id += 1
    end
  end

  # Initialize new surfaces container
  surfaces = init_surfaces(leaf_cell_ids, mesh, Val(V), Val(N), elements)
  n_surfaces = nsurfaces(surfaces)

  # Initialize new mortar containers
  l2mortars, ecmortars = init_mortars(leaf_cell_ids, mesh, Val(V), Val(N), elements, dg.mortar_type)
  n_l2mortars = nmortars(l2mortars)
  n_ecmortars = nmortars(ecmortars)

  # Sanity check
  if n_l2mortars == 0 && n_ecmortars == 0
    @assert n_surfaces == 2*n_elements ("For 2D and periodic domains and conforming elements, "
                                        * "n_surf must be the same as 2*n_elem")
  end

  # Update DG instance with new data
  dg.elements = elements
  dg.n_elements = n_elements
  dg.surfaces = surfaces
  dg.n_surfaces = n_surfaces
  dg.l2mortars = l2mortars
  dg.n_l2mortars = n_l2mortars
  dg.ecmortars = ecmortars
  dg.n_ecmortars = n_ecmortars
end


# Refine solution data u for an element, using L2 projection (interpolation)
function refine_element!(u::AbstractArray{Float64, 4}, element_id::Int,
                         old_u::AbstractArray{Float64, 4}, old_element_id::Int,
                         dg::Dg,
                         forward_upper::AbstractMatrix{Float64},
                         forward_lower::AbstractMatrix{Float64})
  # Store new element ids
  lower_left_id  = element_id
  lower_right_id = element_id + 1
  upper_left_id  = element_id + 2
  upper_right_id = element_id + 3

  # Interpolate to lower left element
  u[:, :, :, lower_left_id] .= 0.0
  for j = 1:nnodes(dg)
    for i = 1:nnodes(dg)
      for l = 1:nnodes(dg)
        for k = 1:nnodes(dg)
          for v = 1:nvariables(dg)
            u[v, i, j, lower_left_id] += (old_u[v, k, l, old_element_id] *
                                          forward_lower[i, k] * forward_lower[j, l])
          end
        end
      end
    end
  end

  # Interpolate to lower right element
  u[:, :, :, lower_right_id] .= 0.0
  for j = 1:nnodes(dg)
    for i = 1:nnodes(dg)
      for l = 1:nnodes(dg)
        for k = 1:nnodes(dg)
          for v = 1:nvariables(dg)
            u[v, i, j, lower_right_id] += (old_u[v, k, l, old_element_id] *
                                           forward_upper[i, k] * forward_lower[j, l])
          end
        end
      end
    end
  end

  # Interpolate to upper left element
  u[:, :, :, upper_left_id] .= 0.0
  for j = 1:nnodes(dg)
    for i = 1:nnodes(dg)
      for l = 1:nnodes(dg)
        for k = 1:nnodes(dg)
          for v = 1:nvariables(dg)
            u[v, i, j, upper_left_id] += (old_u[v, k, l, old_element_id] *
                                          forward_lower[i, k] * forward_upper[j, l])
          end
        end
      end
    end
  end

  # Interpolate to upper right element
  u[:, :, :, upper_right_id] .= 0.0
  for j = 1:nnodes(dg)
    for i = 1:nnodes(dg)
      for l = 1:nnodes(dg)
        for k = 1:nnodes(dg)
          for v = 1:nvariables(dg)
            u[v, i, j, upper_right_id] += (old_u[v, k, l, old_element_id] *
                                           forward_upper[i, k] * forward_upper[j, l])
          end
        end
      end
    end
  end
end


# Coarsen elements in the DG solver based on a list of cell_ids that should be removed
function Solvers.coarsen!(dg::Dg{Eqn, V, N}, mesh::TreeMesh,
                          child_cells_to_coarsen::AbstractArray{Int}) where {Eqn, V, N}
  # Return early if there is nothing to do
  if isempty(child_cells_to_coarsen)
    return
  end

  # Determine for each old element whether it needs to be removed
  to_be_removed = falses(nelements(dg.elements))
  # The "Ref(...)" is such that we can vectorize the search but not the array that is searched
  elements_to_remove = searchsortedfirst.(Ref(dg.elements.cell_ids[1:nelements(dg.elements)]),
                                          child_cells_to_coarsen)
  to_be_removed[elements_to_remove] .= true

  # Retain current solution data
  old_n_elements = nelements(dg.elements)
  old_u = dg.elements.u

  # Get new list of leaf cells
  leaf_cell_ids = leaf_cells(mesh.tree)

  # Initialize new elements container
  elements = init_elements(leaf_cell_ids, mesh, Val(V), Val(N))
  n_elements = nelements(elements)

  # Loop over all elements in old container and either copy them or coarsen them
  skip = 0
  element_id = 1
  for old_element_id in 1:old_n_elements
    # If skip is non-zero, we just coarsened 2^ndim elements and need to omit the following elements
    if skip > 0
      skip -= 1
      continue
    end

    if to_be_removed[old_element_id]
      # If an element is to be removed, sanity check if the following elements
      # are also marked - otherwise there would be an error in the way the
      # cells/elements are sorted
      @assert all(to_be_removed[old_element_id:(old_element_id+2^ndim-1)]) "bad cell/element order"

      # Coarsen elements and store solution directly in new data structure
      coarsen_elements!(elements.u, element_id, old_u, old_element_id, dg,
                        dg.l2mortar_reverse_upper, dg.l2mortar_reverse_lower)
      element_id += 1
      skip = 3
    else
      # Copy old element data to new element container
      @views elements.u[:, :, :, element_id] .= old_u[:, :, :, old_element_id]
      element_id += 1
    end
  end

  # Initialize new surfaces container
  surfaces = init_surfaces(leaf_cell_ids, mesh, Val(V), Val(N), elements)
  n_surfaces = nsurfaces(surfaces)

  # Initialize new mortar containers
  l2mortars, ecmortars = init_mortars(leaf_cell_ids, mesh, Val(V), Val(N), elements, dg.mortar_type)
  n_l2mortars = nmortars(l2mortars)
  n_ecmortars = nmortars(ecmortars)

  # Sanity check
  if n_l2mortars == 0 && n_ecmortars == 0
    @assert n_surfaces == 2*n_elements ("For 2D and periodic domains and conforming elements, "
                                        * "n_surf must be the same as 2*n_elem")
  end

  # Update DG instance with new data
  dg.elements = elements
  dg.n_elements = n_elements
  dg.surfaces = surfaces
  dg.n_surfaces = n_surfaces
  dg.l2mortars = l2mortars
  dg.n_l2mortars = n_l2mortars
  dg.ecmortars = ecmortars
  dg.n_ecmortars = n_ecmortars
end


# Coarsen solution data u for four elements, using L2 projection
function coarsen_elements!(u::AbstractArray{Float64, 4}, element_id::Int,
                           old_u::AbstractArray{Float64, 4}, old_element_id::Int,
                           dg::Dg,
                           reverse_upper::AbstractMatrix{Float64},
                           reverse_lower::AbstractMatrix{Float64})
  # Store old element ids
  lower_left_id  = old_element_id
  lower_right_id = old_element_id + 1
  upper_left_id  = old_element_id + 2
  upper_right_id = old_element_id + 3

  # Reset solution
  u[:, :, :, element_id] .= 0.0

  # Project from lower left element
  for j = 1:nnodes(dg)
    for i = 1:nnodes(dg)
      for l = 1:nnodes(dg)
        for k = 1:nnodes(dg)
          for v = 1:nvariables(dg)
            u[v, i, j, element_id] += (old_u[v, k, l, lower_left_id] *
                                       reverse_lower[i, k] * reverse_lower[j, l])
          end
        end
      end
    end
  end

  # Project from lower right element
  for j = 1:nnodes(dg)
    for i = 1:nnodes(dg)
      for l = 1:nnodes(dg)
        for k = 1:nnodes(dg)
          for v = 1:nvariables(dg)
            u[v, i, j, element_id] += (old_u[v, k, l, lower_right_id] *
                                       reverse_upper[i, k] * reverse_lower[j, l])
          end
        end
      end
    end
  end

  # Project from upper left element
  for j = 1:nnodes(dg)
    for i = 1:nnodes(dg)
      for l = 1:nnodes(dg)
        for k = 1:nnodes(dg)
          for v = 1:nvariables(dg)
            u[v, i, j, element_id] += (old_u[v, k, l, upper_left_id] *
                                       reverse_lower[i, k] * reverse_upper[j, l])
          end
        end
      end
    end
  end

  # Project from upper right element
  for j = 1:nnodes(dg)
    for i = 1:nnodes(dg)
      for l = 1:nnodes(dg)
        for k = 1:nnodes(dg)
          for v = 1:nvariables(dg)
            u[v, i, j, element_id] += (old_u[v, k, l, upper_right_id] *
                                       reverse_upper[i, k] * reverse_upper[j, l])
          end
        end
      end
    end
  end
end


# Calculate an AMR indicator value for each element/leaf cell
#
# The indicator value λ ∈ [-1,1] is ≈ -1 for cells that should be coarsened, ≈
# 0 for cells that should remain as-is, and ≈ 1 for cells that should be
# refined.
#
# Note: The implementation here implicitly assumes that we have an element for
# each leaf cell and that they are in the same order.
#
# FIXME: This is currently implemented for each test case - we need something
# appropriate that is both equation and test case independent
function Solvers.calc_amr_indicator(dg::Dg, mesh::TreeMesh, time::Float64)
  lambda = zeros(dg.n_elements)

  if dg.amr_indicator === :gauss
    base_level = 4
    max_level = 6
    threshold_high = 0.6
    threshold_low = 0.1

    # Iterate over all elements
    for element_id in 1:dg.n_elements
      # Determine target level from peak value
      peak = maximum(dg.elements.u[:, :, :, element_id])
      if peak > threshold_high
        target_level = max_level
      elseif peak > threshold_low
        target_level = max_level - 1
      else
        target_level = base_level
      end

      # Compare target level with actual level to set indicator
      cell_id = dg.elements.cell_ids[element_id]
      actual_level = mesh.tree.levels[cell_id]
      if actual_level < target_level
        lambda[element_id] = 1.0
      elseif actual_level > target_level
        lambda[element_id] = -1.0
      else
        lambda[element_id] = 0.0
      end
    end
  elseif dg.amr_indicator === :isentropic_vortex
    base_level = 3
    max_level = 5
    radius_high = 2
    radius_low = 3

    # Domain size needed to handle periodicity
    domain_length = mesh.tree.length_level_0

    # Get analytical vortex center (based on assumption that center=[0.0,0.0]
    # at t=0.0 and that we stop after one period)
    if time < domain_length/2
      center = Float64[time, time]
    else
      center = Float64[time-domain_length, time-domain_length]
    end

    # Iterate over all elements
    for element_id in 1:dg.n_elements
      cell_id = dg.elements.cell_ids[element_id]
      r = periodic_distance(mesh.tree.coordinates[:, cell_id], center, domain_length)
      if r < radius_high
        target_level = max_level
      elseif r < radius_low
        target_level = max_level - 1
      else
        target_level = base_level
      end

      # Compare target level with actual level to set indicator
      cell_id = dg.elements.cell_ids[element_id]
      actual_level = mesh.tree.levels[cell_id]
      if actual_level < target_level
        lambda[element_id] = 1.0
      elseif actual_level > target_level
        lambda[element_id] = -1.0
      else
        lambda[element_id] = 0.0
      end
    end
  elseif dg.amr_indicator === :blast_wave
    base_level = 4
    max_level = 6
    blending_factor_threshold = 0.01

    # (Re-)initialize element variable storage for blending factor
    if (!haskey(dg.element_variables, :blending_factor) ||
        length(dg.element_variables[:blending_factor]) != dg.n_elements)
      dg.element_variables[:blending_factor] = Vector{Float64}(undef, dg.n_elements)
    end

    alpha = dg.element_variables[:blending_factor]
    out = Any[]
    @timeit timer() "blending factors" calc_blending_factors(alpha, out, dg, dg.elements.u)

    # Iterate over all elements
    for element_id in 1:dg.n_elements
      if alpha[element_id] > blending_factor_threshold
        target_level = max_level
      else
        target_level = base_level
      end

      # Compare target level with actual level to set indicator
      cell_id = dg.elements.cell_ids[element_id]
      actual_level = mesh.tree.levels[cell_id]
      if actual_level < target_level
        lambda[element_id] = 1.0
      elseif actual_level > target_level
        lambda[element_id] = -1.0
      else
        lambda[element_id] = 0.0
      end
    end
  else
    error("unknown AMR indicator '$(dg.amr_indicator)'")
  end

  return lambda
end


# For periodic domains, distance between two points must take into account
# periodic extensions of the domain
function periodic_distance(coordinates, center, domain_length)
  dx = abs.(coordinates - center)
  dx_periodic = min.(dx, domain_length .- dx)
  return sqrt(sum(dx_periodic.^2))
end